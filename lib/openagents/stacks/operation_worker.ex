defmodule OpenAgents.Stacks.OperationWorker do
  @moduledoc """
  Claims and executes durable stack operations.

  The worker polls `stack_operations` for pending rows (and running rows
  whose lease expired, which recovers a crashed worker) and dispatches
  each row by kind: rebases run through `OpenAgents.Stacks.Restack` and
  merges through `OpenAgents.Stacks.Merge`. Claiming uses `FOR UPDATE
  SKIP LOCKED`, so multiple nodes never execute the same operation twice
  inside one lease window.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias OpenAgents.OperationalLog
  alias OpenAgents.Repo
  alias OpenAgents.Stacks.Merge
  alias OpenAgents.Stacks.Operation
  alias OpenAgents.Stacks.Restack

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

      %Operation{} = operation ->
        _result = safe_execute(executor, operation)
        :processed
    end
  end

  @doc "Dispatches one claimed operation to its kind's executor."
  def execute(%Operation{kind: "rebase"} = operation), do: Restack.execute(operation)
  def execute(%Operation{kind: "merge"} = operation), do: Merge.execute(operation)

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

    {:ok, operation} =
      Repo.transaction(fn ->
        operation =
          Repo.one(
            from operation in Operation,
              where:
                (operation.state == "pending" and operation.retry_at <= ^now) or
                  (operation.state == "running" and operation.claimed_at < ^stale_before),
              order_by: [asc: operation.retry_at, asc: operation.inserted_at, asc: operation.id],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        case operation do
          nil ->
            nil

          %Operation{} = claimed ->
            claimed
            |> Operation.transition_changeset(%{
              state: "running",
              attempt_count: claimed.attempt_count + 1,
              claimed_at: now,
              started_at: claimed.started_at || now
            })
            |> Repo.update!()
        end
      end)

    operation
  end

  defp safe_execute(executor, operation) do
    executor.(operation)
  rescue
    error ->
      Logger.warning(
        "stack_operation_crashed operation=#{operation.id} code=#{OperationalLog.code(error)}"
      )

      mark_crashed(operation)
      {:error, :operation_exception}
  catch
    kind, _reason ->
      Logger.warning("stack_operation_crashed operation=#{operation.id} code=#{kind}")
      mark_crashed(operation)
      {:error, :operation_exception}
  end

  defp mark_crashed(operation) do
    operation
    |> Operation.transition_changeset(%{
      state: "failed",
      error: %{"code" => "operation_exception"},
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp poll_interval_ms do
    Application.get_env(:openagents, :stack_operation_worker_poll_interval_ms, 1_000)
  end
end
