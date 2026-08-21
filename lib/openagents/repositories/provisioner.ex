defmodule OpenAgents.Repositories.Provisioner do
  @moduledoc "Claims repository outbox work and materializes durable Git storage."

  use GenServer

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.{Audit, Repo}
  alias OpenAgents.Repositories.{ProvisioningOutbox, Repository}

  @lease_seconds 120
  @maximum_drain 100

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    gen_server_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, gen_server_options)
  end

  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain, 30_000)

  def run_once(executor \\ &execute/1) when is_function(executor, 1) do
    case claim_next() do
      nil ->
        :idle

      %ProvisioningOutbox{} = work ->
        case safe_execute(executor, work) do
          :ok -> complete(work)
          {:error, _reason} -> fail(work)
        end

        :processed
    end
  end

  @impl true
  def init(options) do
    state = %{
      executor: Keyword.get(options, :executor, &execute/1),
      poll_interval_ms: Keyword.get(options, :poll_interval_ms, poll_interval_ms())
    }

    schedule(state.poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, {:ok, drain_now(state.executor, 0)}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    _result = run_once(state.executor)
    schedule(state.poll_interval_ms)
    {:noreply, state}
  end

  defp drain_now(_executor, count) when count >= @maximum_drain, do: count

  defp drain_now(executor, count) do
    case run_once(executor) do
      :processed -> drain_now(executor, count + 1)
      :idle -> count
    end
  end

  defp claim_next do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -@lease_seconds, :second)

    {:ok, work} =
      Repo.transaction(fn ->
        work =
          Repo.one(
            from outbox in ProvisioningOutbox,
              where:
                (outbox.state in ["pending", "failed"] and outbox.retry_at <= ^now) or
                  (outbox.state == "running" and outbox.claimed_at < ^stale_before),
              order_by: [asc: outbox.retry_at, asc: outbox.inserted_at, asc: outbox.id],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        case work do
          nil ->
            nil

          %ProvisioningOutbox{} = claimed ->
            running =
              claimed
              |> ProvisioningOutbox.transition_changeset(%{
                state: "running",
                attempt_count: claimed.attempt_count + 1,
                retry_at: now,
                claimed_at: now,
                completed_at: nil,
                error_code: nil
              })
              |> Repo.update!()

            Audit.record!(
              "repository.provisioning.running",
              :system,
              "provisioning_outbox",
              running.id,
              repository_id: running.repository_id,
              metadata: %{"attempt_count" => running.attempt_count}
            )

            running
        end
      end)

    if work do
      # After the claim commits: a browser watching this repository moves from
      # "queued" to "running" the moment the row does.
      OpenAgents.Repositories.broadcast_provisioning(work.repository_id)
      Repo.preload(work, repository: [:created_by_user, :repository_import])
    end
  end

  defp execute(%ProvisioningOutbox{operation: "create", repository: repository}) do
    initialize_empty(repository)
  end

  defp execute(%ProvisioningOutbox{operation: "github_import", repository: repository}) do
    OpenAgents.Repositories.Importer.import(repository)
  end

  defp initialize_empty(repository) do
    with :ok <- ensure_wal_index(repository.storage_key) do
      Repos.ensure_repo!(repository.storage_key, repository.default_branch)
      :ok
    end
  rescue
    _error -> {:error, :storage_unavailable}
  end

  defp ensure_wal_index(storage_key) do
    case WAL.read_index(storage_key) do
      {:ok, _generation, _index} ->
        :ok

      {:error, :not_found} ->
        case WAL.cas_index(storage_key, :none, WAL.new_index()) do
          {:ok, _generation} -> :ok
          {:error, :cas_conflict} -> ensure_wal_index(storage_key)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_execute(executor, work) do
    case executor.(work) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_executor_result}
    end
  rescue
    _error -> {:error, :provisioning_exception}
  catch
    _kind, _reason -> {:error, :provisioning_exception}
  end

  defp complete(work) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      repository = lock_repository!(work.repository_id)
      outbox = lock_outbox!(work.id)

      repository
      |> Ecto.Changeset.change(
        lifecycle_state: "ready",
        ready_at: now,
        provision_error_code: nil
      )
      |> Repo.update!()

      outbox
      |> ProvisioningOutbox.transition_changeset(%{
        state: "completed",
        attempt_count: outbox.attempt_count,
        retry_at: now,
        claimed_at: outbox.claimed_at,
        completed_at: now,
        error_code: nil
      })
      |> Repo.update!()

      Audit.record!(
        "repository.provisioning.completed",
        :system,
        "provisioning_outbox",
        outbox.id,
        repository_id: repository.id,
        metadata: %{"attempt_count" => outbox.attempt_count, "operation" => outbox.operation}
      )
    end)

    OpenAgents.Repositories.broadcast_provisioning(work.repository_id)
    :ok
  end

  defp fail(work) do
    now = DateTime.utc_now()
    retry_at = DateTime.add(now, retry_delay(work.attempt_count), :second)

    Repo.transaction(fn ->
      repository = lock_repository!(work.repository_id)
      outbox = lock_outbox!(work.id)

      repository
      |> Ecto.Changeset.change(
        lifecycle_state: "failed",
        ready_at: nil,
        provision_error_code: "provisioning_failed"
      )
      |> Repo.update!()

      outbox
      |> ProvisioningOutbox.transition_changeset(%{
        state: "failed",
        attempt_count: outbox.attempt_count,
        retry_at: retry_at,
        claimed_at: outbox.claimed_at,
        completed_at: nil,
        error_code: "provisioning_failed"
      })
      |> Repo.update!()

      Audit.record!("repository.provisioning.failed", :system, "provisioning_outbox", outbox.id,
        repository_id: repository.id,
        metadata: %{
          "attempt_count" => outbox.attempt_count,
          "error_code" => "provisioning_failed",
          "operation" => outbox.operation
        }
      )
    end)

    OpenAgents.Repositories.broadcast_provisioning(work.repository_id)
    Logger.warning("repository_provisioning_failed code=provisioning_failed")
    :ok
  end

  defp lock_repository!(id) do
    Repo.one!(from repository in Repository, where: repository.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_outbox!(id) do
    Repo.one!(from outbox in ProvisioningOutbox, where: outbox.id == ^id, lock: "FOR UPDATE")
  end

  defp retry_delay(attempt_count), do: min(attempt_count * attempt_count * 5, 300)

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp poll_interval_ms do
    Application.get_env(:openagents, :repository_provisioner_poll_interval_ms, 1_000)
  end
end
