defmodule OpenAgents.ContinualLearning.Runner do
  @moduledoc """
  The bounded round loop of one admitted continual-learning job.

  The loop owns nothing about scheduling: it is called by
  `OpenAgents.Work.ContinualLearningServer` inside an ordinary `work_jobs` row.
  What it owns is the durable order of events. Each round writes its checkpoint,
  its usage receipt, its energy receipt, and its training receipt before the
  round counts, so a run that dies between rounds resumes from committed state
  and never from a round it only started.

  The loop stops at the first bound it reaches: the stopping policy, the budget,
  a cancel already written to the row, or a trainer refusal. Only a run that
  reached its stopping policy is evaluated, and only an evaluation the
  accepted-outcome contract accepts produces an artifact, a settlement-ready
  receipt, and the catalog transaction evidence for every consumed listing.
  """

  require Logger

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.ContinualLearning
  alias OpenAgents.ContinualLearning.Artifact
  alias OpenAgents.ContinualLearning.Bounds
  alias OpenAgents.ContinualLearning.Checkpoint
  alias OpenAgents.ContinualLearning.Job
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @doc """
  Runs one job to a terminal state and returns it.

  The return is always a terminal job row: the loop writes the terminal status
  itself, so the caller only has to report it.
  """
  @spec run(String.t()) :: {:ok, Job.t()} | {:error, term()}
  def run(job_id) when is_binary(job_id) do
    with {:ok, job} <- ContinualLearning.fetch(job_id),
         {:ok, running} <- start_running(job) do
      {:ok, loop(running)}
    end
  end

  defp start_running(%Job{} = job) do
    if Job.terminal?(job) do
      {:error, :already_terminal}
    else
      ContinualLearning.update_lifecycle(job, %{
        status: "running",
        started_at: job.started_at || DateTime.utc_now()
      })
    end
  end

  defp loop(%Job{} = job) do
    case next_round(job) do
      {:continue, round} ->
        case train(job, round) do
          {:ok, advanced} -> loop(advanced)
          {:stop, terminal} -> terminal
        end

      {:stop, :stopping_policy_satisfied} ->
        evaluate(job)

      {:stop, reason} ->
        terminal(job, terminal_status(reason), Atom.to_string(reason))
    end
  end

  defp next_round(%Job{} = job) do
    {:ok, current} = ContinualLearning.fetch(job.id)
    maximum = job.stopping_policy["maximum_rounds"] || Bounds.maximum_rounds()

    cond do
      current.status == "cancelled" -> {:stop, :cancelled}
      Job.terminal?(current) -> {:stop, :already_terminal}
      job.rounds_completed >= maximum -> {:stop, :stopping_policy_satisfied}
      target_reached?(job) -> {:stop, :stopping_policy_satisfied}
      exhausted_budget?(job) -> {:stop, :budget_exhausted}
      true -> {:continue, job.rounds_completed + 1}
    end
  end

  defp train(%Job{} = job, round) do
    parent = ContinualLearning.latest_checkpoint(job)

    context = %{
      job: job,
      round: round,
      datasets: job.datasets,
      configuration: job.configuration,
      parent_state: (parent && parent.state) || %{},
      parent_digest: parent && parent.state_digest
    }

    case Bounds.trainer().train_round(context) do
      {:ok, result} ->
        commit_round(job, round, parent, result)

      {:error, reason} ->
        _receipt = ContinualLearning.record_receipt(job, "refusal", %{"reason" => code(reason)})
        {:stop, terminal(job, "failed", code(reason))}
    end
  end

  defp commit_round(%Job{} = job, round, parent, result) do
    energy = energy(job, result)
    usage = round_usage(job, result, energy)

    checkpoint_attributes = %{
      round: round,
      state: result.state,
      state_digest: Canonical.digest!(result.state),
      parent_digest: parent && parent.state_digest,
      metrics: result.metrics,
      usage: usage,
      energy: energy
    }

    outcome =
      Repo.transaction(fn ->
        checkpoint =
          %Checkpoint{job_id: job.id}
          |> Checkpoint.changeset(checkpoint_attributes, Bounds.maximum_state_bytes())
          |> Repo.insert()
          |> unwrap()

        _usage_receipt =
          ContinualLearning.record_receipt(job, "usage", %{
            "round" => round,
            "usage" => usage,
            "budget" => job.budget
          })
          |> unwrap()

        _energy_receipt =
          ContinualLearning.record_receipt(job, "energy", %{
            "round" => round,
            "energy" => energy,
            "runtime_class" => job.runtime_class
          })
          |> unwrap()

        _training_receipt =
          ContinualLearning.record_receipt(job, "training", %{
            "round" => round,
            "checkpoint_digest" => checkpoint.state_digest,
            "parent_digest" => checkpoint.parent_digest,
            "metrics" => result.metrics,
            "dataset_digests" => Enum.map(job.datasets, & &1["artifact_digest"]),
            "training_code_digest" => job.training_code_digest
          })
          |> unwrap()

        job
        |> Job.lifecycle_changeset(%{
          rounds_completed: round,
          usage: accumulate(job.usage, usage)
        })
        |> Repo.update()
        |> unwrap()
      end)

    case outcome do
      {:ok, advanced} -> {:ok, advanced}
      {:error, reason} -> {:stop, terminal(job, "failed", code(reason))}
    end
  end

  defp evaluate(%Job{} = job) do
    checkpoint = ContinualLearning.latest_checkpoint(job)

    context = %{
      job: job,
      corpus: List.wrap(job.evaluation["corpus"]),
      checkpoint: checkpoint,
      policy: job.evaluation
    }

    case Bounds.evaluator().evaluate(context) do
      {:ok, result} ->
        if admitted_evaluator?(job, result) do
          qualify(job, checkpoint, result)
        else
          _receipt =
            ContinualLearning.record_receipt(job, "evaluation", %{
              "state" => "unverifiable",
              "reason" => "evaluator_identity_mismatch",
              "admitted_verifier" => job.evaluation["verifier"]["id"],
              "reported_verifier" => result.verifier["id"]
            })

          terminal(job, "failed", "evaluator_identity_mismatch")
        end

      {:error, reason} ->
        _receipt =
          ContinualLearning.record_receipt(job, "evaluation", %{
            "state" => "unverifiable",
            "reason" => code(reason)
          })

        terminal(job, "failed", code(reason))
    end
  end

  # Separation is checked against the admitted policy, so an evaluator that
  # reports an identity the admission never admitted cannot grade the run.
  defp admitted_evaluator?(%Job{} = job, result) do
    is_map(result.verifier) and result.verifier["id"] == job.evaluation["verifier"]["id"]
  end

  defp qualify(%Job{} = job, checkpoint, result) do
    graded =
      ContinualLearning.grade(job, result, Bounds.outcome_issue())

    case graded do
      {:accepted, outcome} ->
        _receipt =
          ContinualLearning.record_receipt(job, "evaluation", %{
            "state" => "accepted",
            "verifier" => result.verifier,
            "falsifier" => result.falsifier,
            "terminal_result" => Atom.to_string(result.terminal_result),
            "metrics" => result.metrics,
            "corpus_digest" => job.evaluation["corpus_digest"],
            "criteria" => Enum.map(outcome.criteria, & &1.criterion)
          })

        produce_artifact(job, checkpoint, result, outcome)

      {:not_accepted, type, reasons} ->
        _receipt =
          ContinualLearning.record_receipt(job, "evaluation", %{
            "state" => "not_accepted",
            "type" => Atom.to_string(type),
            "reasons" => Enum.map(reasons, &inspect/1),
            "verifier" => result.verifier,
            "terminal_result" => Atom.to_string(result.terminal_result)
          })

        terminal(job, "failed", "evaluation_#{type}")

      {:not_applicable, exemption} ->
        _receipt =
          ContinualLearning.record_receipt(job, "evaluation", %{
            "state" => "not_applicable",
            "exemption" => Atom.to_string(exemption)
          })

        terminal(job, "failed", "evaluation_not_applicable")
    end
  end

  defp produce_artifact(%Job{} = job, checkpoint, result, outcome) do
    chain = job |> ContinualLearning.checkpoints() |> Enum.map(& &1.state_digest)
    corpus = List.wrap(job.evaluation["corpus"])

    evaluation_result = %{
      "verifier" => result.verifier,
      "falsifier" => result.falsifier,
      "terminal_result" => Atom.to_string(result.terminal_result),
      "metrics" => result.metrics,
      "corpus_digest" => job.evaluation["corpus_digest"],
      "target_metric" => job.evaluation["target_metric"],
      "target_value" => job.evaluation["target_value"]
    }

    accepted_outcome = %{
      "state" => "accepted",
      "revision" => outcome.revision,
      "verifier" => outcome.verifier,
      "criteria" => Enum.map(outcome.criteria, & &1.criterion),
      "issue_number" => outcome.issue_number,
      "repository" => outcome.repository
    }

    identity = %{
      "base_model_ref" => job.base_model_ref,
      "base_model_digest" => job.base_model_digest,
      "training_code_digest" => job.training_code_digest,
      "configuration_digest" => job.configuration_digest,
      "dataset_bindings" => job.datasets,
      "evaluation_corpus" => corpus,
      "checkpoint_digests" => chain,
      "final_checkpoint_digest" => checkpoint.state_digest,
      "evaluation_result" => evaluation_result,
      "objective_version" => job.objective_version
    }

    artifact_digest = Canonical.digest!(identity)
    usage = Map.put(job.usage || %{}, "rounds", job.rounds_completed)

    artifact_attributes = %{
      model_ref: "#{job.base_model_ref}+cl.#{job.objective_version}",
      model_digest: Canonical.digest!(Map.take(identity, ["checkpoint_digests"])),
      base_model_digest: job.base_model_digest,
      training_code_digest: job.training_code_digest,
      configuration_digest: job.configuration_digest,
      dataset_bindings: job.datasets,
      checkpoint_digests: chain,
      evaluation_result: evaluation_result,
      accepted_outcome: accepted_outcome,
      artifact_digest: artifact_digest
    }

    settlement =
      ContinualLearning.settlement_payload(
        job,
        %{"artifact_digest" => artifact_digest},
        usage
      )

    outcome_of_insert =
      Repo.transaction(fn ->
        artifact =
          %Artifact{job_id: job.id}
          |> Artifact.changeset(Map.put(artifact_attributes, :settlement, settlement))
          |> Repo.insert()
          |> unwrap()

        _artifact_receipt =
          ContinualLearning.record_receipt(job, "artifact", %{
            "artifact_digest" => artifact.artifact_digest,
            "model_ref" => artifact.model_ref,
            "model_digest" => artifact.model_digest,
            "checkpoint_digests" => artifact.checkpoint_digests,
            "dataset_bindings" => artifact.dataset_bindings,
            "accepted_outcome" => artifact.accepted_outcome
          })
          |> unwrap()

        _settlement_receipt =
          ContinualLearning.record_receipt(job, "settlement", settlement) |> unwrap()

        artifact
      end)

    case outcome_of_insert do
      {:ok, artifact} ->
        _catalog = record_catalog_evidence(job, artifact)
        terminal(job, "completed", nil)

      {:error, reason} ->
        terminal(job, "failed", code(reason))
    end
  end

  # Usage reconciles back into the catalog's own transaction chain: the datasets
  # the job consumed reach `delivery`, `verification`, and `settlement` against
  # the acceptance receipt the buyer already held, so the licensed side of the
  # trade carries the same evidence as the model side.
  defp record_catalog_evidence(%Job{} = job, %Artifact{} = artifact) do
    bindings = job.datasets ++ List.wrap(job.evaluation["corpus"])

    Enum.each(bindings, fn binding ->
      with {:ok, delivery} <-
             catalog_transaction(job, binding, "delivery", binding["acceptance_ref"], nil),
           {:ok, verification} <-
             catalog_transaction(job, binding, "verification", delivery.receipt_ref, nil),
           {:ok, _settlement} <-
             catalog_transaction(
               job,
               binding,
               "settlement",
               verification.receipt_ref,
               artifact.artifact_digest
             ) do
        :ok
      else
        {:error, reason} ->
          Logger.warning(
            "continual_learning_catalog_evidence_skipped job=#{job.id} " <>
              "listing=#{binding["listing_id"]} code=#{code(reason)}"
          )
      end
    end)
  end

  defp catalog_transaction(job, binding, action, predecessor_ref, external_ref) do
    ArtifactCatalog.record_transaction(binding["listing_id"], action, %{
      receipt_ref: "continual-learning:#{job.id}:#{binding["purpose"]}:#{action}",
      predecessor_ref: predecessor_ref,
      external_ref: external_ref || "continual-learning-job:#{job.id}",
      buyer_ref: job.buyer_ref,
      buyer_class: job.buyer_class,
      artifact_digest: binding["artifact_digest"],
      provenance_digest: binding["provenance_digest"],
      license_digest: binding["license_digest"],
      listing_digest: binding["listing_digest"],
      metadata: %{
        "continual_learning_job_id" => job.id,
        "admission_digest" => job.admission_digest,
        "purpose" => binding["purpose"]
      }
    })
  end

  defp terminal(%Job{} = job, status, error_code) do
    case ContinualLearning.terminalize(job, status, error_code) do
      {:ok, terminal} -> terminal
      {:error, _reason} -> job
    end
  end

  defp terminal_status(:budget_exhausted), do: "budget_exhausted"
  defp terminal_status(:cancelled), do: "cancelled"
  defp terminal_status(_reason), do: "failed"

  defp exhausted_budget?(%Job{} = job) do
    spent = Map.get(job.usage || %{}, "cost_usd_cents", 0)
    spent + round_cost(job) > job.budget["amount"]
  end

  defp target_reached?(%Job{} = job) do
    metric = job.evaluation["target_metric"]
    target = job.evaluation["target_value"]

    case ContinualLearning.latest_checkpoint(job) do
      nil ->
        false

      checkpoint ->
        observed = Map.get(checkpoint.metrics, metric)
        is_number(observed) and is_number(target) and observed >= target
    end
  end

  defp round_cost(%Job{runtime_class: runtime_class}),
    do: Bounds.round_cost_usd_cents(runtime_class)

  defp round_usage(%Job{} = job, result, energy) do
    result.usage
    |> Map.put("duration_ms", result.duration_ms)
    |> Map.put("cost_usd_cents", round_cost(job))
    |> Map.put("joules", energy["joules"])
  end

  defp energy(%Job{} = job, result) do
    watts = Map.get(Bounds.class_watts(), job.runtime_class, 0)
    joules = Float.round(watts * result.duration_ms / 1_000, 3)

    %{
      "runtime_class" => job.runtime_class,
      "watts" => watts,
      "duration_ms" => result.duration_ms,
      "joules" => joules,
      "method" => "measured runtime multiplied by the runtime class power draw"
    }
  end

  defp accumulate(previous, usage) when is_map(previous) do
    Enum.reduce(usage, previous, fn {key, value}, acc ->
      case {Map.get(acc, key), value} do
        {nil, value} ->
          Map.put(acc, key, value)

        {existing, value} when is_number(existing) and is_number(value) ->
          Map.put(acc, key, existing + value)

        {_existing, value} ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp unwrap({:ok, record}), do: record
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp code(%Ecto.Changeset{}), do: "invalid_record"
  defp code(_reason), do: "continual_learning_failed"
end
