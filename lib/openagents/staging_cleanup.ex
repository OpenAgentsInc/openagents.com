defmodule OpenAgents.StagingCleanup do
  @moduledoc """
  Registers and removes resources created by one isolated staging test run.

  Cleanup can touch only resources that a harness registered under a bounded
  run ID. Registration is immutable, and cleanup fails closed for the canonical
  repository, administrator accounts, online machines, active work, and account
  data that still has an active turn or voice session.
  """

  import Ecto.Query

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.DataRights
  alias OpenAgents.Machines.Machine
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Staging.DisposableResource
  alias OpenAgents.Voice.{Recording, Session}
  alias OpenAgents.Work.Job

  @run_id_pattern ~r/\A[a-z0-9][a-z0-9-]{7,63}\z/
  @kinds [:account, :machine, :recording, :repository]
  @kind_names Map.new(@kinds, &{&1, Atom.to_string(&1)})
  @schemas %{
    account: User,
    machine: Machine,
    recording: Recording,
    repository: Repository
  }

  @type kind :: :account | :machine | :recording | :repository

  @doc "Registers one disposable resource before a staging harness uses it."
  @spec register(String.t(), kind(), Ecto.UUID.t()) ::
          {:ok, DisposableResource.t()} | {:error, atom() | Ecto.Changeset.t()}
  def register(run_id, kind, resource_id)
      when kind in @kinds and is_binary(run_id) and is_binary(resource_id) do
    with :ok <- ensure_admitted(),
         :ok <- validate_run_id(run_id),
         {:ok, cast_id} <- cast_resource_id(resource_id),
         {:ok, resource} <- fetch_resource(kind, cast_id),
         :ok <- validate_resource(kind, resource) do
      Repo.transaction(fn ->
        lock_run(run_id)

        %DisposableResource{}
        |> DisposableResource.create_changeset(%{
          run_id: run_id,
          kind: Map.fetch!(@kind_names, kind),
          resource_id: cast_id
        })
        |> Repo.insert()
        |> case do
          {:ok, registration} -> registration
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> normalize_transaction()
    end
  end

  def register(_run_id, _kind, _resource_id), do: {:error, :invalid_registration}

  @doc "Returns content-free registration counts for one run."
  @spec preview(String.t()) :: {:ok, map()} | {:error, atom()}
  def preview(run_id) when is_binary(run_id) do
    with :ok <- ensure_admitted(),
         :ok <- validate_run_id(run_id) do
      {:ok, %{registered: registration_counts(run_id)}}
    end
  end

  def preview(_run_id), do: {:error, :invalid_run_id}

  @doc "Removes every resource registered to one run in a single transaction."
  @spec cleanup(String.t()) :: {:ok, map()} | {:error, atom() | tuple()}
  def cleanup(run_id) when is_binary(run_id) do
    with :ok <- ensure_admitted(),
         :ok <- validate_run_id(run_id) do
      Repo.transaction(fn ->
        lock_run(run_id)

        registrations =
          Repo.all(
            from(resource in DisposableResource,
              where: resource.run_id == ^run_id,
              order_by: [asc: resource.kind, asc: resource.resource_id],
              lock: "FOR UPDATE"
            )
          )

        registered = counts(registrations)
        targets = targets(registrations)

        validate_cleanup_targets!(targets)

        deleted = %{
          recording: delete_recordings(targets.recording),
          repository: delete_repositories(targets.repository),
          machine: delete_machines(targets.machine),
          account: delete_accounts(targets.account)
        }

        {_registration_count, nil} =
          Repo.delete_all(from(resource in DisposableResource, where: resource.run_id == ^run_id))

        %{registered: registered, deleted: stringify_counts(deleted)}
      end)
      |> normalize_transaction()
    end
  end

  def cleanup(_run_id), do: {:error, :invalid_run_id}

  @doc "Returns one bounded JSON result for the staging operator command."
  @spec command!(String.t(), String.t()) :: String.t()
  def command!(run_id, "check") do
    case preview(run_id) do
      {:ok, result} -> encode_result(run_id, "checked", result)
      {:error, reason} -> raise "staging cleanup refused: #{bounded_reason(reason)}"
    end
  end

  def command!(run_id, "apply") do
    case cleanup(run_id) do
      {:ok, result} -> encode_result(run_id, "cleaned", result)
      {:error, reason} -> raise "staging cleanup refused: #{bounded_reason(reason)}"
    end
  end

  def command!(_run_id, _mode), do: raise("staging cleanup mode is invalid")

  defp ensure_admitted do
    environment = Application.get_env(:openagents, :runtime_environment)
    enabled? = Application.get_env(:openagents, :staging_cleanup_enabled, false) == true
    staging_gate = Application.get_env(:openagents, :staging_gate, 0)

    if enabled? and
         (environment == :test or (environment == :staging and staging_gate >= 12)) do
      :ok
    else
      {:error, :staging_cleanup_not_admitted}
    end
  end

  defp validate_run_id(run_id) do
    if Regex.match?(@run_id_pattern, run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp cast_resource_id(resource_id) do
    case Ecto.UUID.cast(resource_id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> {:error, :invalid_resource_id}
    end
  end

  defp fetch_resource(kind, resource_id) do
    case Repo.get(Map.fetch!(@schemas, kind), resource_id) do
      nil -> {:error, :resource_not_found}
      resource -> {:ok, resource}
    end
  end

  defp validate_resource(:repository, %Repository{
         owner_key: "openagentsinc",
         name_key: "openagents.com"
       }),
       do: {:error, :canonical_repository_forbidden}

  defp validate_resource(:account, %User{} = user) do
    if Accounts.admin?(user), do: {:error, :administrator_account_forbidden}, else: :ok
  end

  defp validate_resource(_kind, _resource), do: :ok

  defp lock_run(run_id) do
    _result = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [run_id])
    :ok
  end

  defp registration_counts(run_id) do
    Repo.all(
      from(resource in DisposableResource,
        where: resource.run_id == ^run_id,
        group_by: resource.kind,
        select: {resource.kind, count(resource.id)}
      )
    )
    |> Map.new()
    |> complete_counts()
  end

  defp counts(registrations) do
    registrations
    |> Enum.frequencies_by(& &1.kind)
    |> complete_counts()
  end

  defp complete_counts(counts) do
    Map.new(Map.values(@kind_names), &{&1, Map.get(counts, &1, 0)})
  end

  defp stringify_counts(counts) do
    Map.new(@kinds, fn kind -> {Map.fetch!(@kind_names, kind), Map.fetch!(counts, kind)} end)
  end

  defp targets(registrations) do
    by_kind = Enum.group_by(registrations, & &1.kind, & &1.resource_id)

    %{
      account: Map.get(by_kind, "account", []),
      machine: Map.get(by_kind, "machine", []),
      recording: Map.get(by_kind, "recording", []),
      repository: Map.get(by_kind, "repository", [])
    }
  end

  defp validate_cleanup_targets!(targets) do
    validate_repositories!(targets.repository)

    validate_accounts!(
      targets.account,
      targets.repository,
      targets.machine,
      targets.recording
    )

    validate_machines!(targets.machine)
  end

  defp validate_repositories!(repository_ids) do
    canonical? =
      Repo.exists?(
        from(repository in Repository,
          where:
            repository.id in ^repository_ids and repository.owner_key == "openagentsinc" and
              repository.name_key == "openagents.com"
        )
      )

    if canonical?, do: Repo.rollback(:canonical_repository_forbidden)
  end

  defp validate_accounts!(account_ids, repository_ids, machine_ids, recording_ids) do
    users = Repo.all(from(user in User, where: user.id in ^account_ids, lock: "FOR UPDATE"))

    if Enum.any?(users, &Accounts.admin?/1),
      do: Repo.rollback(:administrator_account_forbidden)

    outside_project? =
      Repo.exists?(
        from(project in Project,
          where:
            project.owner_user_id in ^account_ids and
              project.repository_id not in ^repository_ids
        )
      )

    if outside_project?, do: Repo.rollback(:account_owns_unregistered_project)

    outside_machine? =
      Repo.exists?(
        from(machine in Machine,
          where: machine.user_id in ^account_ids and machine.id not in ^machine_ids
        )
      )

    if outside_machine?, do: Repo.rollback(:account_owns_unregistered_machine)

    outside_recording? =
      Repo.exists?(
        from(recording in Recording,
          join: session in Session,
          on: session.id == recording.voice_session_id,
          join: conversation in Conversation,
          on: conversation.id == session.conversation_id,
          join: visitor in Visitor,
          on: visitor.id == conversation.visitor_id,
          where: visitor.user_id in ^account_ids and recording.id not in ^recording_ids
        )
      )

    if outside_recording?, do: Repo.rollback(:account_owns_unregistered_recording)
  end

  defp validate_machines!(machine_ids) do
    if Enum.any?(machine_ids, &OpenAgents.Computer.online?/1),
      do: Repo.rollback(:machine_online)

    active_work? =
      Repo.exists?(
        from(job in Job,
          where: job.machine_id in ^machine_ids and job.status in ["queued", "running"]
        )
      )

    if active_work?, do: Repo.rollback(:machine_has_active_work)
  end

  defp delete_recordings([]), do: 0

  defp delete_recordings(recording_ids) do
    {count, nil} =
      Repo.delete_all(from(recording in Recording, where: recording.id in ^recording_ids))

    count
  end

  defp delete_repositories([]), do: 0

  defp delete_repositories(repository_ids) do
    project_ids =
      from(project in Project,
        where: project.repository_id in ^repository_ids,
        select: project.id
      )

    {_field_count, nil} =
      Repo.delete_all(
        from(field in ProjectField, where: field.project_id in subquery(project_ids))
      )

    {_item_count, nil} =
      Repo.delete_all(from(item in ProjectItem, where: item.repository_id in ^repository_ids))

    {count, nil} =
      Repo.delete_all(from(repository in Repository, where: repository.id in ^repository_ids))

    count
  end

  defp delete_machines([]), do: 0

  defp delete_machines(machine_ids) do
    {_job_count, nil} = Repo.delete_all(from(job in Job, where: job.machine_id in ^machine_ids))
    {count, nil} = Repo.delete_all(from(machine in Machine, where: machine.id in ^machine_ids))
    count
  end

  defp delete_accounts([]), do: 0

  defp delete_accounts(account_ids) do
    account_ids
    |> Enum.sort()
    |> Enum.count(fn account_id ->
      case Repo.get(User, account_id) do
        nil ->
          false

        %User{} = user ->
          delete_account_data!(user)

          case Repo.delete(user) do
            {:ok, _deleted} -> true
            {:error, _changeset} -> Repo.rollback(:account_delete_failed)
          end
      end
    end)
  end

  defp delete_account_data!(user) do
    case Conversations.get_conversation_for_user(user) do
      nil ->
        :ok

      conversation ->
        owner = Conversations.get_conversation_owner!(conversation)

        case DataRights.delete(user, owner, conversation) do
          {:ok, :deleted} -> :ok
          {:error, reason} -> Repo.rollback({:account_data_cleanup_failed, reason})
        end
    end
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp encode_result(run_id, status, result) do
    Jason.encode!(%{
      "schema" => "openagents.staging_cleanup.v1",
      "run_id" => run_id,
      "status" => status,
      "registered" => result.registered,
      "deleted" => Map.get(result, :deleted)
    })
  end

  defp bounded_reason({:account_data_cleanup_failed, reason}) when is_atom(reason),
    do: "account_data_#{reason}"

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bounded_reason(%Ecto.Changeset{}), do: "registration_conflict"
  defp bounded_reason(_reason), do: "cleanup_failed"
end
