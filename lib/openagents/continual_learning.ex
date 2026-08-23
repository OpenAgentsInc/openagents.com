defmodule OpenAgents.ContinualLearning do
  @moduledoc """
  Bounded continual-learning jobs over verified licensed datasets.

  One named internal buyer starts a job that names a versioned objective, an
  admitted base model, exact licensed dataset references, an evaluation corpus,
  a budget, a runtime class, and a stopping policy. Admission resolves every
  dataset through `OpenAgents.ArtifactCatalog`, so a job holds the exact
  artifact, provenance, license, and listing digests it trained on, and a
  removed listing, an expired license, a license that does not admit training,
  or a buyer class the listing was not licensed to refuses before any capacity
  is spent. Fleet admission is `OpenAgents.Capacity.match/2`: this lane adds no
  second scheduler, and the run itself is an ordinary `work_jobs` row of kind
  `continual_learning` driven by `OpenAgents.Work.ContinualLearningServer`.

  Every round writes a durable checkpoint before it is counted, so resume and
  replay are different acts: a resume continues the surviving checkpoint chain
  under the same admission digest, and a replay is a new job that starts from
  round zero. A lost checkpoint refuses the resume instead of retraining
  silently.

  Evaluation is graded through `OpenAgents.AcceptedOutcome`, under the admitted
  evaluator policy, so a failed, unevidenced, or non-independent evaluation
  cannot produce a qualified artifact. A qualified artifact binds the exact base
  model, dataset, code, configuration, checkpoint, and evaluation digests, and
  the job's settlement-ready receipt names the buyer, the unit, the amount, and
  the treasury policy without moving money.

  See `INVARIANTS.md`, CONTINUAL-001.
  """

  import Ecto.Query

  alias OpenAgents.AcceptedOutcome
  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.Capacity
  alias OpenAgents.ContinualLearning.Artifact
  alias OpenAgents.ContinualLearning.Bounds
  alias OpenAgents.ContinualLearning.Checkpoint
  alias OpenAgents.ContinualLearning.Job
  alias OpenAgents.ContinualLearning.Receipt
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Settlement
  alias OpenAgents.Work

  @active_statuses ~w(queued running)
  @evaluation_purpose "evaluation"
  @training_purpose "delivery"

  # ── admission ──────────────────────────────────────────────────────────────

  @doc """
  Admits and starts one continual-learning job for the named buyer.

  Returns `{:ok, job}` with a queued job whose run is already supervised, or a
  typed refusal.
  """
  @spec start(User.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def start(%User{} = user, attributes) when is_map(attributes) do
    with :ok <- feature_enabled(),
         :ok <- operator(user),
         {:ok, buyer_ref} <- buyer_ref(attributes),
         {:ok, buyer_class} <- buyer_class(),
         {:ok, objective} <- objective(attributes),
         {:ok, objective_version} <- objective_version(attributes),
         {:ok, base_model} <- base_model(attributes),
         {:ok, training_code_digest} <- training_code_digest(),
         {:ok, configuration} <- configuration(attributes),
         {:ok, runtime_class} <- runtime_class(attributes),
         {:ok, conversation_id} <- identifier(attributes, :conversation_id),
         {:ok, owner_visitor_id} <- identifier(attributes, :owner_visitor_id),
         {:ok, datasets} <- datasets(attributes, buyer_ref, buyer_class, runtime_class),
         {:ok, evaluation} <- evaluation(attributes, buyer_ref, buyer_class, runtime_class),
         {:ok, budget} <- budget(attributes),
         {:ok, stopping_policy} <- stopping_policy(attributes),
         :ok <- concurrency(),
         {:ok, capacity_receipt} <- capacity(user, runtime_class, budget, stopping_policy) do
      admission = %{
        buyer_ref: buyer_ref,
        buyer_class: buyer_class,
        objective: objective,
        objective_version: objective_version,
        base_model_ref: base_model.ref,
        base_model_digest: base_model.digest,
        training_code_digest: training_code_digest,
        configuration: configuration,
        configuration_digest: Canonical.digest!(configuration),
        datasets: datasets,
        evaluation: evaluation,
        budget: budget,
        runtime_class: runtime_class,
        capacity_receipt: capacity_receipt,
        stopping_policy: stopping_policy,
        replay_of_id: Map.get(attributes, :replay_of_id)
      }

      with {:ok, job} <- insert_job(admission),
           {:ok, started} <-
             launch(job, conversation_id, owner_visitor_id, "admission") do
        {:ok, started}
      end
    end
  end

  def start(_user, _attributes), do: {:error, :operator_required}

  @doc "One job the buyer may read, or a typed refusal."
  @spec get(User.t(), String.t()) :: {:ok, Job.t()} | {:error, term()}
  def get(%User{} = user, id) when is_binary(id) do
    with :ok <- operator(user), do: fetch(id)
  end

  def get(_user, _id), do: {:error, :operator_required}

  @doc "The buyer's most recent jobs, newest first, bounded."
  @spec list(User.t(), pos_integer()) :: {:ok, [Job.t()]} | {:error, term()}
  def list(%User{} = user, limit \\ 50) do
    with :ok <- operator(user) do
      bounded = min(max(limit, 1), 200)

      buyer_ref = Bounds.buyer_ref()

      {:ok,
       Job
       |> where([job], job.buyer_ref == ^buyer_ref)
       |> order_by([job], desc: job.inserted_at)
       |> limit(^bounded)
       |> Repo.all()}
    end
  end

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Cancels one active job.

  The durable row reaches `cancelled` here, so the round loop stops at its next
  boundary even when the worker is already gone.
  """
  @spec cancel(User.t(), String.t()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(%User{} = user, id) when is_binary(id) do
    with :ok <- operator(user),
         {:ok, job} <- fetch(id) do
      cond do
        job.status == "cancelled" ->
          {:ok, job}

        Job.terminal?(job) ->
          {:error, :not_cancellable}

        true ->
          if job.work_job_id, do: Work.cancel_job(job.work_job_id)
          terminalize(job, "cancelled", "cancelled")
      end
    end
  end

  def cancel(_user, _id), do: {:error, :operator_required}

  @doc """
  Resumes one interrupted or budget-exhausted job from its surviving checkpoint.

  A resume is not a replay: the job keeps its admission digest, its receipt
  chain, and its checkpoints, and continues at the next round. It refuses when
  the checkpoint is gone, when a dataset's license no longer admits the job, or
  when the fleet cannot admit the runtime class again.
  """
  @spec resume(User.t(), String.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def resume(%User{} = user, id, attributes \\ %{}) do
    with :ok <- feature_enabled(),
         :ok <- operator(user),
         {:ok, job} <- fetch(id),
         :ok <- resumable(job),
         {:ok, checkpoint} <- surviving_checkpoint(job),
         :ok <- rounds_remaining(job),
         :ok <- budget_remaining(job),
         :ok <- reverify_datasets(job),
         {:ok, capacity_receipt} <-
           capacity(user, job.runtime_class, job.budget, job.stopping_policy),
         {:ok, conversation_id, owner_visitor_id} <- previous_surface(job, attributes),
         {:ok, resumed} <- mark_resumed(job, checkpoint, capacity_receipt) do
      launch(resumed, conversation_id, owner_visitor_id, "resume")
    end
  end

  @doc """
  Replays one job as a new job under the same admitted inputs.

  A replay re-resolves every licensed dataset and the fleet again, starts at
  round zero, and records the job it replays, so a reproducibility check never
  reuses the original job's checkpoints.
  """
  @spec replay(User.t(), String.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def replay(%User{} = user, id, attributes) when is_map(attributes) do
    with :ok <- operator(user),
         {:ok, job} <- fetch(id),
         {:ok, conversation_id, owner_visitor_id} <- previous_surface(job, attributes) do
      start(
        user,
        replay_attributes(job, %{
          conversation_id: conversation_id,
          owner_visitor_id: owner_visitor_id
        })
      )
    end
  end

  @doc "Records one append-only receipt for a job."
  @spec record_receipt(Job.t(), String.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
  def record_receipt(%Job{} = job, kind, payload) when is_binary(kind) and is_map(payload) do
    sequence = Repo.aggregate(from(r in Receipt, where: r.job_id == ^job.id), :count) + 1
    body = Map.put(payload, "recorded_at", DateTime.to_iso8601(DateTime.utc_now()))

    %Receipt{job_id: job.id}
    |> Receipt.changeset(%{
      kind: kind,
      sequence: sequence,
      receipt_ref: "continual-learning-#{kind}:#{job.id}:#{sequence}",
      payload: body,
      digest: Canonical.digest!(Map.put(body, "job_id", job.id))
    })
    |> Repo.insert()
  end

  @doc "The bounded evidence export for one job."
  @spec export_evidence(User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export_evidence(%User{} = user, id) when is_binary(id) do
    with :ok <- operator(user),
         {:ok, job} <- fetch(id) do
      {:ok,
       %{
         "schema" => "openagents.continual_learning_evidence.v1",
         "exported_at" => DateTime.utc_now(),
         "job" => projection(job),
         "checkpoints" => Enum.map(checkpoints(job), &checkpoint_projection/1),
         "receipts" => Enum.map(receipts(job), &receipt_projection/1),
         "artifact" => artifact_projection(artifact(job))
       }}
    end
  end

  @doc "The ordered checkpoint chain of one job."
  @spec checkpoints(Job.t()) :: [Checkpoint.t()]
  def checkpoints(%Job{} = job) do
    Checkpoint
    |> where([checkpoint], checkpoint.job_id == ^job.id)
    |> order_by([checkpoint], asc: checkpoint.round)
    |> Repo.all()
  end

  @doc "The ordered receipts of one job."
  @spec receipts(Job.t()) :: [Receipt.t()]
  def receipts(%Job{} = job) do
    Receipt
    |> where([receipt], receipt.job_id == ^job.id)
    |> order_by([receipt], asc: receipt.sequence)
    |> Repo.all()
  end

  @doc "The terminal artifact of one job, or `nil`."
  @spec artifact(Job.t()) :: Artifact.t() | nil
  def artifact(%Job{} = job), do: Repo.get_by(Artifact, job_id: job.id)

  @doc "The latest checkpoint of one job, or `nil`."
  @spec latest_checkpoint(Job.t()) :: Checkpoint.t() | nil
  def latest_checkpoint(%Job{} = job) do
    Checkpoint
    |> where([checkpoint], checkpoint.job_id == ^job.id)
    |> order_by([checkpoint], desc: checkpoint.round)
    |> limit(1)
    |> Repo.one()
  end

  @doc "How many continual-learning jobs are queued or running right now."
  @spec active_count() :: non_neg_integer()
  def active_count do
    Repo.aggregate(from(job in Job, where: job.status in ^@active_statuses), :count)
  end

  @doc "Reloads one job by id."
  @spec fetch(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def fetch(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Job, uuid) do
          nil -> {:error, :not_found}
          job -> {:ok, job}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Moves a job's lifecycle fields."
  @spec update_lifecycle(Job.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def update_lifecycle(%Job{} = job, attributes) when is_map(attributes) do
    job
    |> Job.lifecycle_changeset(attributes)
    |> Repo.update()
  end

  @doc """
  Terminalizes a job once. An already-terminal job is returned unchanged, so a
  cancel racing the round loop cannot rewrite the first terminal state.
  """
  @spec terminalize(Job.t(), String.t(), String.t() | nil) :: {:ok, Job.t()} | {:error, term()}
  def terminalize(%Job{} = job, status, error_code) do
    Repo.transaction(fn ->
      locked =
        Job
        |> where([row], row.id == ^job.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(locked) ->
          Repo.rollback(:not_found)

        Job.terminal?(locked) ->
          locked

        true ->
          locked
          |> Job.lifecycle_changeset(%{
            status: status,
            error_code: error_code,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @doc "The public projection of one job."
  @spec projection(Job.t()) :: map()
  def projection(%Job{} = job) do
    %{
      "id" => job.id,
      "buyer_ref" => job.buyer_ref,
      "buyer_class" => job.buyer_class,
      "objective" => job.objective,
      "objective_version" => job.objective_version,
      "base_model_ref" => job.base_model_ref,
      "base_model_digest" => job.base_model_digest,
      "training_code_digest" => job.training_code_digest,
      "configuration_digest" => job.configuration_digest,
      "datasets" => job.datasets,
      "evaluation" => job.evaluation,
      "budget" => job.budget,
      "runtime_class" => job.runtime_class,
      "capacity_receipt" => job.capacity_receipt,
      "stopping_policy" => job.stopping_policy,
      "admission_digest" => job.admission_digest,
      "status" => job.status,
      "error_code" => job.error_code,
      "rounds_completed" => job.rounds_completed,
      "resume_count" => job.resume_count,
      "usage" => job.usage,
      "work_job_id" => job.work_job_id,
      "replay_of_id" => job.replay_of_id,
      "started_at" => job.started_at,
      "completed_at" => job.completed_at
    }
  end

  # ── dataset admission ──────────────────────────────────────────────────────

  @doc """
  Resolves one licensed dataset reference into its exact binding.

  The listing must be available, licensed to the job's buyer class, licensed
  for the requested use, and licensed for the custody the runtime class
  provides, and the buyer must already hold an admitted acceptance receipt.
  """
  @spec bind_dataset(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def bind_dataset(reference, purpose, buyer_ref, buyer_class, runtime_class)
      when is_map(reference) do
    with {:ok, listing_id} <- reference_field(reference, "listing_id"),
         {:ok, acceptance_ref} <- reference_field(reference, "acceptance_ref"),
         {:ok, access} <- authorize(listing_id, purpose, buyer_ref, acceptance_ref),
         {:ok, listing} <- available_listing(listing_id),
         :ok <- licensed_buyer_class(listing, buyer_class),
         :ok <- licensed_use(listing, purpose),
         :ok <- licensed_custody(listing, runtime_class) do
      {:ok,
       %{
         "listing_id" => listing.id,
         "acceptance_ref" => acceptance_ref,
         "purpose" => purpose,
         "source_ref_digest" => Canonical.sha256(access.source_ref),
         "artifact_digest" => listing.artifact_digest,
         "provenance_digest" => listing.provenance_digest,
         "license_digest" => listing.license_digest,
         "listing_digest" => listing.listing_digest,
         "license_contract_ref" => listing.license_contract_ref,
         "license_expires_at" => DateTime.to_iso8601(listing.license_expires_at),
         "record_count" => listing.record_count
       }}
    end
  end

  defp datasets(attributes, buyer_ref, buyer_class, runtime_class) do
    references = Map.get(attributes, :datasets)

    cond do
      not is_list(references) or references == [] ->
        {:error, :datasets_required}

      length(references) > Bounds.maximum_datasets() ->
        {:error, :too_many_datasets}

      true ->
        bind_all(references, @training_purpose, buyer_ref, buyer_class, runtime_class)
    end
  end

  defp bind_all(references, purpose, buyer_ref, buyer_class, runtime_class) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, bound} ->
      case bind_dataset(reference, purpose, buyer_ref, buyer_class, runtime_class) do
        {:ok, binding} -> {:cont, {:ok, bound ++ [binding]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authorize(listing_id, purpose, buyer_ref, acceptance_ref) do
    case ArtifactCatalog.authorize_source_access(listing_id, %{
           purpose: purpose,
           buyer_ref: buyer_ref,
           acceptance_ref: acceptance_ref
         }) do
      {:ok, access} ->
        {:ok, access}

      # The catalog distinguishes a listing that is gone from one whose license
      # window closed, and the refusal has to keep that distinction.
      {:error, reason} when reason in [:not_found, :listing_removed, :stale_license] ->
        {:error, {:dataset_unavailable, reason}}

      {:error, reason} ->
        {:error, {:dataset_not_authorized, reason}}
    end
  end

  defp available_listing(listing_id) do
    case ArtifactCatalog.get_public_listing(listing_id) do
      {:ok, listing} -> {:ok, listing}
      {:error, reason} -> {:error, {:dataset_unavailable, reason}}
    end
  end

  defp licensed_buyer_class(listing, buyer_class) do
    if listing.buyer_class == buyer_class,
      do: :ok,
      else: {:error, {:dataset_buyer_class_mismatch, listing.id}}
  end

  defp licensed_use(listing, purpose) do
    terms = listing.license_terms || %{}
    allowed = List.wrap(terms["allowed_uses"])
    use_name = if purpose == @evaluation_purpose, do: "evaluation", else: "training"

    cond do
      terms["opt_in"] != true -> {:error, {:consent_missing, listing.id}}
      use_name not in allowed -> {:error, {:use_not_licensed, listing.id, use_name}}
      true -> :ok
    end
  end

  defp licensed_custody(listing, runtime_class) do
    location = data_location(runtime_class)
    licensed = List.wrap((listing.license_terms || %{})["data_locations"])

    cond do
      location not in Bounds.admitted_custody() ->
        {:error, {:unsupported_custody, location}}

      licensed != [] and location not in licensed ->
        {:error, {:unsupported_custody, listing.id}}

      true ->
        :ok
    end
  end

  defp reverify_datasets(%Job{} = job) do
    bindings = job.datasets ++ List.wrap(get_in(job.evaluation, ["corpus"]))

    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      case bind_dataset(
             binding,
             binding["purpose"],
             job.buyer_ref,
             job.buyer_class,
             job.runtime_class
           ) do
        {:ok, rebound} ->
          if rebound["license_digest"] == binding["license_digest"] and
               rebound["artifact_digest"] == binding["artifact_digest"] do
            {:cont, :ok}
          else
            {:halt, {:error, {:dataset_moved, binding["listing_id"]}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # ── evaluation admission ───────────────────────────────────────────────────

  defp evaluation(attributes, buyer_ref, buyer_class, runtime_class) do
    case Map.get(attributes, :evaluation) do
      evaluation when is_map(evaluation) ->
        admit_evaluation(evaluation, buyer_ref, buyer_class, runtime_class)

      _missing ->
        {:error, :evaluation_required}
    end
  end

  defp admit_evaluation(evaluation, buyer_ref, buyer_class, runtime_class) do
    with {:ok, corpus} <-
           corpus(evaluation, buyer_ref, buyer_class, runtime_class),
         {:ok, verifier} <- verifier(evaluation),
         {:ok, criteria} <- acceptance_criteria(evaluation),
         {:ok, target} <- target_metric(evaluation) do
      {:ok,
       %{
         "corpus" => corpus,
         "corpus_digest" => Canonical.digest!(Enum.map(corpus, & &1["artifact_digest"])),
         "verifier" => verifier,
         "separation_required" => evaluation[:separation_required] == true,
         "acceptance_criteria" => criteria,
         "target_metric" => target.metric,
         "target_value" => target.value,
         "policy_version" => Map.get(evaluation, :policy_version, 1)
       }}
    end
  end

  defp corpus(evaluation, buyer_ref, buyer_class, runtime_class) do
    references = Map.get(evaluation, :corpus)

    cond do
      not is_list(references) or references == [] ->
        {:error, :evaluation_corpus_required}

      length(references) > Bounds.maximum_datasets() ->
        {:error, :too_many_datasets}

      true ->
        bind_all(references, @evaluation_purpose, buyer_ref, buyer_class, runtime_class)
    end
  end

  defp verifier(evaluation) do
    verifier = Map.get(evaluation, :verifier)
    separation = evaluation[:separation_required] == true

    cond do
      not is_map(verifier) or not is_binary(verifier[:id]) ->
        {:error, :evaluator_required}

      verifier[:admitted] != true ->
        {:error, :evaluator_not_admitted}

      separation and verifier[:independent_of_producer] != true ->
        {:error, :evaluator_not_independent}

      true ->
        {:ok,
         %{
           "id" => verifier[:id],
           "admitted" => true,
           "independent_of_producer" => verifier[:independent_of_producer] == true,
           "policy_digest" => Canonical.digest!(%{"verifier" => verifier[:id]})
         }}
    end
  end

  defp acceptance_criteria(evaluation) do
    criteria = List.wrap(Map.get(evaluation, :acceptance_criteria))

    if criteria != [] and Enum.all?(criteria, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, criteria}
    else
      {:error, :acceptance_criteria_required}
    end
  end

  defp target_metric(evaluation) do
    metric = Map.get(evaluation, :target_metric)
    value = Map.get(evaluation, :target_value)

    if is_binary(metric) and metric != "" and is_number(value) do
      {:ok, %{metric: metric, value: value}}
    else
      {:error, :evaluation_target_required}
    end
  end

  # ── other admission checks ─────────────────────────────────────────────────

  defp feature_enabled do
    if Bounds.enabled?(), do: :ok, else: {:error, :continual_learning_disabled}
  end

  defp operator(user) do
    if Accounts.admin?(user), do: :ok, else: {:error, :operator_required}
  end

  defp buyer_ref(attributes) do
    admitted = Bounds.buyer_ref()
    requested = Map.get(attributes, :buyer_ref)

    cond do
      not is_binary(admitted) or admitted == "" -> {:error, :buyer_not_configured}
      requested != admitted -> {:error, :buyer_not_admitted}
      true -> {:ok, admitted}
    end
  end

  defp buyer_class do
    case Bounds.buyer_class() do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :buyer_not_configured}
    end
  end

  defp objective(attributes) do
    case Map.get(attributes, :objective) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" and byte_size(trimmed) <= 2_000,
          do: {:ok, trimmed},
          else: {:error, :objective_invalid}

      _missing ->
        {:error, :objective_invalid}
    end
  end

  defp objective_version(attributes) do
    case Map.get(attributes, :objective_version) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :objective_version_invalid}
    end
  end

  defp base_model(attributes) do
    admitted = Bounds.admitted_base_models()
    requested = Map.get(attributes, :base_model_ref)
    digest = Map.get(attributes, :base_model_digest)

    case Map.fetch(admitted, requested) do
      {:ok, admitted_digest} when is_binary(digest) and digest != admitted_digest ->
        {:error, :base_model_digest_mismatch}

      {:ok, admitted_digest} ->
        {:ok, %{ref: requested, digest: admitted_digest}}

      :error ->
        {:error, :base_model_not_admitted}
    end
  end

  defp training_code_digest do
    case Bounds.training_code_digest() do
      value when is_binary(value) -> {:ok, value}
      _missing -> {:error, :training_code_not_pinned}
    end
  end

  defp configuration(attributes) do
    case Map.get(attributes, :configuration, %{}) do
      value when is_map(value) ->
        if byte_size(Jason.encode!(value)) <= 8_192,
          do: {:ok, value},
          else: {:error, :configuration_too_large}

      _invalid ->
        {:error, :configuration_invalid}
    end
  end

  defp runtime_class(attributes) do
    requested = Map.get(attributes, :runtime_class)

    if is_binary(requested) and requested in Bounds.runtime_classes(),
      do: {:ok, requested},
      else: {:error, :runtime_class_not_admitted}
  end

  defp budget(attributes) do
    case Map.get(attributes, :budget) do
      %{} = budget ->
        amount = budget[:usd_cents] || budget["usd_cents"]

        if is_integer(amount) and amount > 0,
          do: {:ok, %{"unit" => "usd_cents", "amount" => amount}},
          else: {:error, :budget_invalid}

      _missing ->
        {:error, :budget_invalid}
    end
  end

  defp stopping_policy(attributes) do
    policy = Map.get(attributes, :stopping_policy)
    rounds = is_map(policy) && (policy[:maximum_rounds] || policy["maximum_rounds"])

    cond do
      not is_map(policy) ->
        {:error, :stopping_policy_required}

      not (is_integer(rounds) and rounds > 0) ->
        {:error, :stopping_policy_required}

      rounds > Bounds.maximum_rounds() ->
        {:error, :stopping_policy_exceeds_bound}

      true ->
        minimum_improvement = policy[:minimum_improvement] || policy["minimum_improvement"] || 0.0

        {:ok,
         %{
           "maximum_rounds" => rounds,
           "minimum_improvement" => minimum_improvement,
           "wall_clock_ms" => Bounds.wall_clock_ms()
         }}
    end
  end

  defp concurrency do
    if active_count() < Bounds.concurrency_limit(),
      do: :ok,
      else: {:error, :continual_learning_at_capacity}
  end

  defp capacity(user, runtime_class, budget, stopping_policy) do
    requirement = %{
      "quantity" => 1,
      "isolation" => isolation(runtime_class),
      "egress" => "policy_broker",
      "data_location" => data_location(runtime_class),
      "target" => "openagents_managed",
      "tools" => ["shell"],
      "duration_seconds" => duration_seconds(stopping_policy),
      "budget" => %{"currency" => "usd_cents", "amount" => budget["amount"]}
    }

    case Capacity.match(user, requirement) do
      {:ok, match} ->
        candidate = Enum.find(match["candidates"], &(&1["class"] == runtime_class))

        if candidate do
          {:ok,
           %{
             "schema" => match["schema"],
             "matched_at" => match["generated_at"],
             "requirement" => match["requirement"],
             "class" => candidate["class"],
             "rank" => candidate["rank"],
             "evidence" => candidate["evidence"],
             "estimate" => candidate["estimate"]
           }}
        else
          {:error, {:capacity_unavailable, runtime_class}}
        end

      {:error, %{"error" => %{"code" => code}}} ->
        {:error, {:capacity_unavailable, code}}
    end
  end

  defp isolation("strong"), do: "managed_strong"
  defp isolation(_class), do: "managed_standard"

  defp data_location(_class), do: "openagents_managed"

  defp duration_seconds(stopping_policy) do
    stopping_policy
    |> Map.get("wall_clock_ms", Bounds.wall_clock_ms())
    |> div(1_000)
    |> max(1)
  end

  defp identifier(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :"#{key}_required"}
    end
  end

  # A dataset reference arrives either from the JSON API (string keys) or from
  # an internal caller (atom keys); both name the same admitted listing.
  defp reference_field(reference, "listing_id"),
    do: reference_value(reference, "listing_id", :listing_id)

  defp reference_field(reference, "acceptance_ref"),
    do: reference_value(reference, "acceptance_ref", :acceptance_ref)

  defp reference_value(reference, string_key, atom_key) do
    case Map.get(reference, string_key) || Map.get(reference, atom_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:dataset_reference_invalid, string_key}}
    end
  end

  # ── insertion and launch ───────────────────────────────────────────────────

  defp insert_job(admission) do
    digest =
      Canonical.digest!(%{
        "buyer_ref" => admission.buyer_ref,
        "objective" => admission.objective,
        "objective_version" => admission.objective_version,
        "base_model_digest" => admission.base_model_digest,
        "training_code_digest" => admission.training_code_digest,
        "configuration_digest" => admission.configuration_digest,
        "dataset_digests" => Enum.map(admission.datasets, & &1["artifact_digest"]),
        "license_digests" => Enum.map(admission.datasets, & &1["license_digest"]),
        "evaluation_corpus_digest" => admission.evaluation["corpus_digest"],
        "verifier_policy_digest" => admission.evaluation["verifier"]["policy_digest"],
        "runtime_class" => admission.runtime_class,
        "stopping_policy" => admission.stopping_policy,
        "budget" => admission.budget
      })

    Repo.transaction(fn ->
      changeset =
        Job.admission_changeset(%Job{}, Map.put(admission, :admission_digest, digest))

      with {:ok, job} <- Repo.insert(changeset),
           {:ok, _receipt} <-
             record_receipt(job, "admission", %{
               "admission_digest" => job.admission_digest,
               "buyer_ref" => job.buyer_ref,
               "buyer_class" => job.buyer_class,
               "objective_version" => job.objective_version,
               "base_model_ref" => job.base_model_ref,
               "base_model_digest" => job.base_model_digest,
               "training_code_digest" => job.training_code_digest,
               "configuration_digest" => job.configuration_digest,
               "datasets" => job.datasets,
               "evaluation" => Map.drop(job.evaluation, ["corpus"]),
               "evaluation_corpus" => job.evaluation["corpus"],
               "runtime_class" => job.runtime_class,
               "capacity_receipt" => job.capacity_receipt,
               "budget" => job.budget,
               "stopping_policy" => job.stopping_policy,
               "replay_of_id" => job.replay_of_id
             }) do
        job
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp launch(%Job{} = job, conversation_id, owner_visitor_id, cause) do
    case Work.start_continual_learning(%{
           conversation_id: conversation_id,
           owner_visitor_id: owner_visitor_id,
           surface: "text",
           goal: job.objective,
           delegation: %{
             "continual_learning_job_id" => job.id,
             "admission_digest" => job.admission_digest,
             "cause" => cause,
             "resume_count" => job.resume_count
           },
           authority_snapshot: %{
             "buyer_ref" => job.buyer_ref,
             "buyer_class" => job.buyer_class,
             "runtime_class" => job.runtime_class,
             "base_model_ref" => job.base_model_ref,
             "base_model_digest" => job.base_model_digest,
             "training_code_digest" => job.training_code_digest,
             "verifier_id" => job.evaluation["verifier"]["id"]
           },
           budget_snapshot: Bounds.snapshot(job.runtime_class)
         }) do
      {:ok, work_job} ->
        update_lifecycle(job, %{work_job_id: work_job.id})

      {:error, reason} ->
        _refusal = record_receipt(job, "refusal", %{"reason" => inspect(reason)})
        _terminal = terminalize(job, "failed", "worker_start_failed")
        {:error, reason}
    end
  end

  defp resumable(%Job{} = job) do
    if Job.resumable?(job), do: :ok, else: {:error, :not_resumable}
  end

  defp surviving_checkpoint(%Job{} = job) do
    case latest_checkpoint(job) do
      nil -> {:error, :checkpoint_missing}
      %Checkpoint{lost: true} -> {:error, :checkpoint_lost}
      %Checkpoint{} = checkpoint -> verify_chain(job, checkpoint)
    end
  end

  defp verify_chain(%Job{} = job, %Checkpoint{} = checkpoint) do
    recomputed = Canonical.digest!(checkpoint.state)

    if recomputed == checkpoint.state_digest and checkpoint.round == job.rounds_completed do
      {:ok, checkpoint}
    else
      {:error, :checkpoint_lost}
    end
  end

  # A resume spends the admitted budget, so a job that already spent all of it
  # has to be admitted again rather than resumed into the same stop.
  defp budget_remaining(%Job{} = job) do
    spent = Map.get(job.usage || %{}, "cost_usd_cents", 0)
    amount = job.budget["amount"] || 0

    if spent + Bounds.round_cost_usd_cents(job.runtime_class) <= amount,
      do: :ok,
      else: {:error, :budget_exhausted}
  end

  defp rounds_remaining(%Job{} = job) do
    maximum = job.stopping_policy["maximum_rounds"] || Bounds.maximum_rounds()
    if job.rounds_completed < maximum, do: :ok, else: {:error, :stopping_policy_satisfied}
  end

  defp previous_surface(%Job{work_job_id: nil}, attributes) do
    with {:ok, conversation_id} <- identifier(attributes, :conversation_id),
         {:ok, owner_visitor_id} <- identifier(attributes, :owner_visitor_id) do
      {:ok, conversation_id, owner_visitor_id}
    end
  end

  defp previous_surface(%Job{work_job_id: work_job_id}, attributes) do
    case Work.get_job(work_job_id) do
      nil -> previous_surface(%Job{work_job_id: nil}, attributes)
      work_job -> {:ok, work_job.conversation_id, work_job.owner_visitor_id}
    end
  end

  defp mark_resumed(%Job{} = job, %Checkpoint{} = checkpoint, capacity_receipt) do
    with {:ok, _receipt} <-
           record_receipt(job, "resume", %{
             "from_round" => checkpoint.round,
             "checkpoint_digest" => checkpoint.state_digest,
             "admission_digest" => job.admission_digest,
             "previous_status" => job.status,
             "previous_work_job_id" => job.work_job_id,
             "resume_count" => job.resume_count + 1,
             "capacity_receipt" => capacity_receipt
           }),
         {:ok, resumed} <-
           update_lifecycle(job, %{
             status: "queued",
             error_code: nil,
             completed_at: nil,
             resume_count: job.resume_count + 1,
             work_job_id: nil
           }) do
      {:ok, resumed}
    end
  end

  defp replay_attributes(%Job{} = job, attributes) do
    %{
      buyer_ref: job.buyer_ref,
      objective: job.objective,
      objective_version: job.objective_version,
      base_model_ref: job.base_model_ref,
      base_model_digest: job.base_model_digest,
      configuration: job.configuration,
      runtime_class: job.runtime_class,
      datasets: Enum.map(job.datasets, &Map.take(&1, ["listing_id", "acceptance_ref"])),
      evaluation: %{
        corpus:
          Enum.map(
            List.wrap(job.evaluation["corpus"]),
            &Map.take(&1, ["listing_id", "acceptance_ref"])
          ),
        verifier: %{
          id: job.evaluation["verifier"]["id"],
          admitted: true,
          independent_of_producer: job.evaluation["verifier"]["independent_of_producer"]
        },
        separation_required: job.evaluation["separation_required"],
        acceptance_criteria: job.evaluation["acceptance_criteria"],
        target_metric: job.evaluation["target_metric"],
        target_value: job.evaluation["target_value"],
        policy_version: job.evaluation["policy_version"]
      },
      budget: %{usd_cents: job.budget["amount"]},
      stopping_policy: %{
        maximum_rounds: job.stopping_policy["maximum_rounds"],
        minimum_improvement: job.stopping_policy["minimum_improvement"]
      },
      replay_of_id: job.id,
      conversation_id: Map.get(attributes, :conversation_id),
      owner_visitor_id: Map.get(attributes, :owner_visitor_id)
    }
  end

  # ── settlement readiness ───────────────────────────────────────────────────

  @doc """
  The settlement-ready receipt payload for a qualified job.

  The lane records authority and evidence, never custody: the payload names the
  buyer, the unit, the metered amount, the treasury policy that would pay it,
  and the artifact it settles, and states that no transfer happened here.
  """
  @spec settlement_payload(Job.t(), map(), map()) :: map()
  def settlement_payload(%Job{} = job, artifact_payload, usage) do
    %{
      "settlement_policy_id" => Settlement.policy_id(),
      "unit" => Bounds.settlement_unit(),
      "buyer_ref" => job.buyer_ref,
      "buyer_class" => job.buyer_class,
      "amount" => usage["cost_usd_cents"],
      "budget" => job.budget,
      "artifact_digest" => artifact_payload["artifact_digest"],
      "accepted_outcome_state" => "accepted",
      "usage" => usage,
      "transferred" => false,
      "custody" => "no_custody_moves_in_this_lane"
    }
  end

  @doc """
  Grades one evaluation result against the accepted-outcome contract.

  The claim is built from the admitted evaluator policy and the job's own
  identity, so the contract, not this lane, decides whether the artifact is
  qualified.
  """
  @spec grade(Job.t(), map(), map()) ::
          {:accepted, map()} | {:not_accepted, atom(), [term()]} | {:not_applicable, atom()}
  def grade(%Job{} = job, result, %{repository: repository, issue_number: issue_number}) do
    policy = job.evaluation

    AcceptedOutcome.evaluate(%{
      actor: :agent,
      agents_enabled: true,
      issue: %{
        number: issue_number,
        repository: repository,
        sections: %{
          problem: job.objective,
          scope: "continual-learning job #{job.id}",
          acceptance_criteria: policy["acceptance_criteria"],
          success_metrics: "#{policy["target_metric"]} >= #{policy["target_value"]}"
        }
      },
      attempt: %{
        issue_number: issue_number,
        repository: repository,
        authority: job.buyer_ref,
        budget: job.budget,
        revision: job.admission_digest
      },
      verification: %{
        verifier: %{
          id: policy["verifier"]["id"],
          admitted: policy["verifier"]["admitted"] == true,
          independent_of_producer: policy["verifier"]["independent_of_producer"] == true
        },
        falsifier: result.falsifier,
        terminal_result: result.terminal_result,
        separation_required: policy["separation_required"] == true,
        false_green_classes: []
      },
      evidence:
        Enum.map(result.criteria, fn item ->
          %{
            criterion: item["criterion"],
            receipt: item["receipt"],
            visibility: visibility(item["visibility"])
          }
        end)
    })
  end

  defp visibility("public"), do: :public
  defp visibility(_restricted), do: :restricted

  # ── projections ────────────────────────────────────────────────────────────

  defp checkpoint_projection(%Checkpoint{} = checkpoint) do
    %{
      "round" => checkpoint.round,
      "state_digest" => checkpoint.state_digest,
      "parent_digest" => checkpoint.parent_digest,
      "metrics" => checkpoint.metrics,
      "usage" => checkpoint.usage,
      "energy" => checkpoint.energy,
      "lost" => checkpoint.lost,
      "recorded_at" => checkpoint.inserted_at
    }
  end

  defp receipt_projection(%Receipt{} = receipt) do
    %{
      "kind" => receipt.kind,
      "sequence" => receipt.sequence,
      "receipt_ref" => receipt.receipt_ref,
      "digest" => receipt.digest,
      "payload" => receipt.payload
    }
  end

  defp artifact_projection(nil), do: nil

  defp artifact_projection(%Artifact{} = artifact) do
    %{
      "model_ref" => artifact.model_ref,
      "model_digest" => artifact.model_digest,
      "base_model_digest" => artifact.base_model_digest,
      "training_code_digest" => artifact.training_code_digest,
      "configuration_digest" => artifact.configuration_digest,
      "dataset_bindings" => artifact.dataset_bindings,
      "checkpoint_digests" => artifact.checkpoint_digests,
      "evaluation_result" => artifact.evaluation_result,
      "accepted_outcome" => artifact.accepted_outcome,
      "settlement" => artifact.settlement,
      "artifact_digest" => artifact.artifact_digest
    }
  end
end
