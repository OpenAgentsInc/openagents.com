defmodule OpenAgents.SCV.CodexRun do
  @moduledoc "Owns one durable, locally isolated Codex-backed SCV execution."

  use GenServer, restart: :temporary

  alias OpenAgents.SCV
  alias OpenAgents.SCV.CodexAccounts
  alias OpenAgents.SCV.Executions
  alias OpenAgents.SCV.Workspace

  def child_spec(options) do
    execution = Keyword.fetch!(options, :execution)

    %{
      id: {__MODULE__, execution.id},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    {:ok,
     %{
       account: Keyword.fetch!(options, :account),
       execution: Keyword.fetch!(options, :execution),
       repository: Keyword.fetch!(options, :repository),
       terminal?: false,
       workspace: nil
     }, {:continue, :prepare_workspace}}
  end

  @impl true
  def handle_continue(:prepare_workspace, state) do
    case Workspace.prepare(
           state.repository,
           state.execution.repository_revision,
           state.execution.id
         ) do
      {:ok, workspace} ->
        {:noreply, %{state | workspace: workspace}, {:continue, :execute}}

      {:error, reason} ->
        complete(state, failure_result(error_code(reason)))
    end
  end

  def handle_continue(:execute, state) do
    execution = state.execution

    run_options = [
      driver: :codex_app_server,
      environment: :codex_app_server,
      permission_profile: :read_only,
      repository_revision: execution.repository_revision,
      run_id: execution.id,
      driver_options: [
        account: state.account,
        reasoning_effort: execution.reasoning_effort,
        event_sink: &Executions.record_event(execution, &1),
        session_sink: &Executions.record_session(execution, &1),
        credential_sink: &CodexAccounts.refresh_credential(state.account, &1)
      ]
    ]

    outcome = SCV.run(state.workspace, execution.objective, run_options)
    complete(state, normalize_outcome(outcome))
  rescue
    _error -> complete(state, failure_result("scv_process_failed"))
  catch
    _kind, _reason -> complete(state, failure_result("scv_process_failed"))
  after
    Workspace.destroy(state.workspace)
  end

  @impl true
  def terminate(_reason, %{terminal?: true}), do: :ok

  def terminate(_reason, state) do
    if is_binary(state.workspace), do: Workspace.destroy(state.workspace)
    :ok
  end

  defp complete(state, result) do
    _event = maybe_emit_terminal_event(state.execution, result)

    case Executions.finish(state.execution, result) do
      {:ok, _updated} -> {:stop, :normal, %{state | terminal?: true}}
      {:error, reason} -> {:stop, {:terminal_persistence_failed, reason}, state}
    end
  end

  defp maybe_emit_terminal_event(_execution, %{terminal_event_emitted: true}), do: :ok

  defp maybe_emit_terminal_event(execution, result) do
    event = %{
      schema: "openagents.scv.event.v1",
      run_id: execution.id,
      type: "run_finished",
      emitted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      driver: "codex_app_server",
      model: "gpt-5.6-luna",
      reasoning_effort: execution.reasoning_effort,
      status: result.status,
      error_code: result.error_code
    }

    with :ok <- Executions.record_event(execution, event) do
      :telemetry.execute([:openagents, :scv, :event], %{count: 1}, event)
      :ok
    end
  end

  defp normalize_outcome({:ok, result}) when is_map(result), do: result
  defp normalize_outcome({:error, reason}), do: failure_result(error_code(reason))
  defp normalize_outcome(_outcome), do: failure_result("scv_result_invalid")

  defp failure_result(code) do
    text = "The SCV failed before it produced a terminal report."

    %{
      status: "failed",
      error_code: code,
      report: %{text: text},
      usage: %{},
      resources: %{}
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "scv_execution_failed"
end
