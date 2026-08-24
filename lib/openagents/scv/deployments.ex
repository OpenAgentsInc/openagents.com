defmodule OpenAgents.SCV.Deployments do
  @moduledoc """
  The one admitted entry point for deploying an SCV on our own capacity
  (SCV-001).

  Every surface that can start an SCV — Sarah's `scv_deploy` tool today, an
  operator surface tomorrow — enters here, so operator authority, the
  repository's identity, the exact revision, the objective bound, and the
  concurrency ceiling cannot drift apart between callers. This mirrors
  `OpenAgents.ComputerAgentJobs`, which does the same job for delegations to a
  person's own machine.

  Two facts make this lane different from every other tool Sarah holds, and
  both are enforced here rather than described:

  - **It spends our capacity, not the caller's.** A delegation ends on hardware
    the person owns and powers; an SCV ends on ours. So the authority required
    is operator authority — `OpenAgents.Accounts.admin?/1` — checked against the
    account behind the conversation, in the code that starts the run, not only
    in whatever advertised the tool.
  - **It is bounded before it starts.** The objective is capped, the wall clock
    and output ceiling are snapshotted onto the row at admission, and the number
    of SCVs running at once across the whole application is capped, so a model
    that decides to deploy in a loop is refused at the second or third call
    rather than at the invoice.

  The run itself is a `work_jobs` row of kind `scv`; nothing here is a second
  job system.
  """

  import Ecto.Query

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Work
  alias OpenAgents.Work.Job
  alias OpenAgents.Work.Scv

  @active_statuses ~w(queued running)

  @doc """
  Start one bounded SCV deployment for an operator.

  Returns `{:ok, job}` with a queued-or-running `work_jobs` row, or a typed
  refusal. The caller acknowledges the job reference immediately; the run
  reports back into the conversation when it ends.
  """
  @spec start(User.t(), map()) :: {:ok, Job.t()} | {:error, atom()}
  def start(%User{} = user, attributes) when is_map(attributes) do
    with :ok <- feature_enabled(),
         :ok <- operator(user),
         {:ok, objective} <- objective(attributes),
         {:ok, conversation_id} <- identifier(attributes, :conversation_id),
         {:ok, owner_visitor_id} <- identifier(attributes, :owner_visitor_id),
         {:ok, repository} <- repository(user, attributes),
         {:ok, revision} <- revision(repository),
         :ok <- capacity() do
      Work.start_scv(%{
        conversation_id: conversation_id,
        owner_visitor_id: owner_visitor_id,
        surface: surface(attributes),
        goal: objective,
        delegation: %{
          "objective" => objective,
          "repository_path" => "#{repository.owner}/#{repository.name}"
        },
        authority_snapshot:
          Scv.authority_snapshot(%{owner: user, repository: repository, revision: revision}),
        budget_snapshot: Scv.budget_snapshot()
      })
    end
  end

  def start(_user, _attributes), do: {:error, :operator_required}

  @doc "How many SCV deployments are queued or running right now."
  @spec active_count() :: non_neg_integer()
  def active_count do
    Repo.aggregate(
      from(job in Job, where: job.kind == ^Scv.kind() and job.status in ^@active_statuses),
      :count
    )
  end

  @doc """
  The approval receipts that admit the SCV deployment module for one operator.

  Operating the SCV lane is an operator act, so the receipt carries
  `explicit_operator_approval` and points at the operator account. A
  non-operator receives no receipt at all, which is what makes
  `OpenAgents.Modules.SurfacePolicy` refuse the call a second time,
  independently of the check in `start/2`.
  """
  @spec approval_receipts(User.t() | nil, String.t()) :: [map()]
  def approval_receipts(user, scope_ref) when is_binary(scope_ref) do
    if Accounts.admin?(user) do
      [
        %{
          "schema" => "sarah.module_approval.v1",
          "approval_class" => "explicit_operator_approval",
          "module_id" => "sarah.tool.scv_deploy.v1",
          "version" => 1,
          "scope_ref" => scope_ref,
          "explicit" => true,
          "actor_type" => "operator",
          "receipt_ref" => "operator:#{user.id}"
        }
      ]
    else
      []
    end
  end

  # ── admission ──────────────────────────────────────────────────────────────

  defp feature_enabled do
    if Scv.enabled?(), do: :ok, else: {:error, :scv_deploy_disabled}
  end

  defp operator(user) do
    if Accounts.admin?(user), do: :ok, else: {:error, :operator_required}
  end

  defp objective(attributes) do
    case Map.get(attributes, :objective) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" and byte_size(trimmed) <= Scv.maximum_objective_bytes(),
          do: {:ok, trimmed},
          else: {:error, :scv_objective_invalid}

      _missing ->
        {:error, :scv_objective_invalid}
    end
  end

  defp identifier(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) -> {:ok, value}
      _missing -> {:error, :scope_refused}
    end
  end

  defp surface(attributes) do
    case Map.get(attributes, :surface) do
      value when value in ["text", "voice"] -> value
      _other -> "text"
    end
  end

  # The repository is named the way a person names it, and resolved to a row
  # the operator may actually read. An SCV never reaches a repository through a
  # filesystem path the caller supplied.
  defp repository(user, attributes) do
    # The read predicate is composed, not restated. The copy this replaced
    # admitted any membership row rather than one in a reading role, and
    # resolved the path without the namespace-alias join a rename leaves behind
    # (REPOSITORY-001).
    with path when is_binary(path) <- Map.get(attributes, :repository),
         [owner, name] <- String.split(String.trim(path), "/", parts: 2),
         %Repository{} = repository <- Repositories.visible_by_path(owner, name, user) do
      {:ok, repository}
    else
      _unavailable -> {:error, :scv_repository_not_found}
    end
  end

  defp revision(%Repository{} = repository) do
    if Repos.valid_storage_key?(repository.storage_key) do
      refs = Repos.refs(repository.storage_key)

      case Map.get(refs, "refs/heads/#{repository.default_branch}") do
        sha when is_binary(sha) ->
          if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
            do: {:ok, sha},
            else: {:error, :scv_repository_revision_unavailable}

        _missing ->
          {:error, :scv_repository_revision_unavailable}
      end
    else
      {:error, :scv_repository_not_found}
    end
  end

  defp capacity do
    if active_count() < Scv.concurrency_limit(),
      do: :ok,
      else: {:error, :scv_capacity_reached}
  end
end
