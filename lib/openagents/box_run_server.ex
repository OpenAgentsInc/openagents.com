defmodule OpenAgents.BoxRunServer do
  @moduledoc false

  use GenServer

  alias OpenAgents.Box.Client
  alias OpenAgents.Box.Run
  alias OpenAgents.BoxRuns
  alias OpenAgents.Repo

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(run_id) do
    GenServer.start_link(__MODULE__, run_id, name: via(run_id))
  end

  @impl true
  def init(run_id) do
    case Repo.get(Run, run_id) do
      %Run{} = run -> {:ok, %{run: run}, {:continue, :drive}}
      nil -> :ignore
    end
  end

  @impl true
  def handle_continue(:drive, state) do
    next_state = drive(state)

    if terminal_state?(next_state.run) do
      {:stop, :normal, next_state}
    else
      {:noreply, next_state}
    end
  end

  @impl true
  def handle_cast(:cancel, %{run: %Run{} = run} = state) do
    if Run.terminal?(run) do
      {:stop, :normal, state}
    else
      result =
        case Client.cancel_run(box_id(run), run.id, run.run_directory) do
          {:ok, %{"cancelled" => false}} -> {:error, :cancellation_pid_missing}
          {:ok, _body} -> BoxRuns.mark_cancellation_effective(run.id)
          {:error, reason} -> {:error, reason}
        end

      case result do
        {:ok, updated} -> {:stop, :normal, %{state | run: updated}}
        {:error, _reason} -> {:noreply, schedule_poll(state)}
      end
    end
  end

  @impl true
  def handle_info(:poll, %{run: %Run{} = run} = state) do
    case Repo.get(Run, run.id) do
      %Run{} = refreshed ->
        if Run.terminal?(refreshed) do
          {:stop, :normal, %{state | run: refreshed}}
        else
          next_state = poll(%{state | run: refreshed})

          if terminal_state?(next_state.run) do
            {:stop, :normal, next_state}
          else
            {:noreply, next_state}
          end
        end

      nil ->
        {:stop, :normal, state}
    end
  end

  defp drive(%{run: %Run{} = run} = state) do
    cond do
      Run.terminal?(run) ->
        state

      DateTime.compare(DateTime.utc_now(), run.deadline_at) != :lt ->
        _ = BoxRuns.mark_timeout(run.id)
        _ = cancel_for_timeout(run)
        schedule_poll(state)

      is_nil(run.dispatch_attempted_at) ->
        dispatch(state)

      is_nil(run.probe_attempted_at) and run.state == "admitted" ->
        probe(state)

      true ->
        schedule_poll(state)
    end
  end

  defp dispatch(%{run: run} = state) do
    case BoxRuns.claim_dispatch(run.id) do
      {:ok, claimed} ->
        case Client.dispatch_run(
               box_id(claimed),
               claimed.id,
               claimed.command,
               claimed.run_directory
             ) do
          {:ok, pid} ->
            {:ok, updated} = BoxRuns.mark_dispatched(claimed.id, pid)
            schedule_poll(%{state | run: updated})

          {:error, :box_unreachable} ->
            probe(%{state | run: claimed})

          {:error, reason} when reason in [:box_not_found, :box_stopped] ->
            _ = BoxRuns.mark_lost(claimed.id, Atom.to_string(reason))
            %{state | run: %{claimed | state: "lost"}}

          {:error, reason} ->
            _ = BoxRuns.finish(claimed.id, "failed", nil, dispatch_failure_reason(reason))
            %{state | run: %{claimed | state: "failed"}}
        end

      {:error, _reason} ->
        schedule_poll(state)
    end
  end

  defp probe(%{run: run} = state) do
    {:ok, _run} = BoxRuns.mark_probe_attempted(run.id)

    case Client.probe_run(box_id(run), run.id, run.run_directory) do
      {:ok, %{present: true, pid: pid}} ->
        {:ok, updated} = BoxRuns.mark_dispatched(run.id, pid || run.pid)
        schedule_poll(%{state | run: updated})

      _missing ->
        _ = BoxRuns.mark_lost(run.id, "dispatch_ambiguous")
        %{state | run: %{run | state: "lost"}}
    end
  end

  defp poll(%{run: run} = state) do
    case retry_cancellation(run) do
      {:ok, updated} ->
        Process.send_after(self(), :poll, 0)
        %{state | run: updated}

      :retry_poll ->
        poll_provider(state)
    end
  end

  defp poll_provider(%{run: run} = state) do
    case Client.poll_run(box_id(run), run.id, run.last_output_offset, run.run_directory) do
      {:ok, %{present: false}} ->
        _ = BoxRuns.mark_lost(run.id, "run_directory_missing")
        %{state | run: %{run | state: "lost"}}

      {:ok, %{alive: false, exit_status: nil}} ->
        _ = BoxRuns.mark_lost(run.id, "process_missing_without_exit_sentinel")
        %{state | run: %{run | state: "lost"}}

      {:ok, result} ->
        {:ok, updated} = BoxRuns.record_poll(run.id, result)

        cond do
          result.exit_status != nil ->
            terminal = if result.exit_status == 0, do: "completed", else: "failed"
            {:ok, updated} = BoxRuns.finish(run.id, terminal, result.exit_status)
            %{state | run: updated}

          DateTime.compare(DateTime.utc_now(), updated.deadline_at) != :lt ->
            _ = BoxRuns.mark_timeout(updated.id)
            _ = cancel_for_timeout(updated)
            schedule_poll(%{state | run: %{updated | timed_out: true}})

          true ->
            schedule_poll(%{state | run: updated})
        end

      {:error, reason} ->
        if reason in [:box_not_found, :box_stopped] or box_gone_error?(reason) do
          _ = BoxRuns.mark_lost(run.id, loss_reason(reason))
          %{state | run: %{run | state: "lost"}}
        else
          schedule_poll(state)
        end
    end
  end

  defp retry_cancellation(
         %Run{cancellation_requested_at: requested, cancellation_effective_at: nil} = run
       )
       when not is_nil(requested) do
    case Client.cancel_run(box_id(run), run.id, run.run_directory) do
      {:ok, %{"cancelled" => false}} -> :retry_poll
      {:ok, _body} -> BoxRuns.mark_cancellation_effective(run.id)
      {:error, _reason} -> :retry_poll
    end
  end

  defp retry_cancellation(_run), do: :retry_poll

  defp cancel_for_timeout(run) do
    case Client.cancel_run(box_id(run), run.id, run.run_directory) do
      {:ok, _body} ->
        _ = BoxRuns.finish(run.id, "timed_out", nil, "run_duration_exceeded")
        :ok

      {:error, _reason} ->
        _ = BoxRuns.finish(run.id, "timed_out", nil, "run_duration_exceeded")
        :ok
    end
  end

  defp dispatch_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp dispatch_failure_reason(_reason), do: "dispatch_failed"

  defp box_gone_error?({:box_request_refused, _status, code})
       when code in ["box_stopped", "box_not_found", "box_gone"],
       do: true

  defp box_gone_error?(_reason), do: false

  defp loss_reason({:box_request_refused, _status, code}), do: code
  defp loss_reason(reason), do: Atom.to_string(reason)

  defp schedule_poll(%{run: run} = state) do
    Process.send_after(self(), :poll, poll_interval())
    %{state | run: run}
  end

  defp poll_interval do
    :openagents
    |> Application.get_env(:box_api, [])
    |> Keyword.get(:run_poll_interval_ms, 1_000)
    |> max(1)
  end

  defp box_id(%Run{conversation_box: %{box_id: box_id}}), do: box_id

  defp box_id(%Run{conversation_box_id: id}) do
    Repo.get!(OpenAgents.Box.ConversationBox, id).box_id
  end

  defp terminal_state?(%Run{} = run), do: Run.terminal?(run)

  defp via(run_id), do: {:via, Registry, {OpenAgents.BoxRunRegistry, run_id}}
end
