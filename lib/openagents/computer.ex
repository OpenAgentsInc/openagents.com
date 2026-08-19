defmodule OpenAgents.Computer do
  @moduledoc """
  Server-side view of connected computer controllers.

  A connected machine's channel process registers under `{:machine, machine_id}`
  in the cluster-wide `OpenAgents.HordeRegistry`, so any node in the fleet can reach
  a controller regardless of which node terminates its WebSocket (channel pids
  are location-transparent). Requests are correlated by a server-minted
  `request_id` and answered by the controller over the channel; the caller
  waits bounded and never blocks on an offline machine.

  While a streamed request runs, `OpenAgents.ComputerActivity` re-broadcasts a
  bounded projection of the stream on the machine owner's conversation topic —
  a live view only; the collected output returned here stays the authority
  for the durable tool-step outcome.
  """

  alias OpenAgents.ComputerActivity

  # Cluster-wide (Horde) so a delegation relocated to a survivor node can still
  # reach a controller whose WebSocket terminates on a different node — channel
  # pids are location-transparent, so `send/2` crosses nodes unchanged (M2).
  @registry OpenAgents.HordeRegistry
  @probe_timeout_ms 15_000
  @run_timeout_ms 120_000
  @agent_timeout_ms 3_600_000
  @maximum_collected_bytes 65_536

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:sarah, :computer_controller_enabled, false)

  @spec register(String.t()) :: {:ok, pid()} | {:error, term()}
  def register(machine_id) do
    case OpenAgents.Cluster.Registry.register(@registry, {:machine, machine_id}, []) do
      {:ok, _owner} = ok ->
        broadcast_presence(machine_id, :online)
        ok

      # A dead node's registration lingers until the cluster detects the loss
      # and prunes it (bounded by net_ticktime). A controller reconnecting
      # through the fleet LB lands in that window; refuse softly so the channel
      # can reject the join and the client retries, rather than crash-looping.
      {:error, {:already_registered, _stale}} ->
        {:error, :already_registered}
    end
  end

  @doc "Subscribes the caller to one owned computer's presence and record events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(machine_id) when is_binary(machine_id) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, machine_topic(machine_id))
  end

  @doc "Explicitly unregisters the calling controller and announces it offline."
  @spec unregister(String.t()) :: :ok
  def unregister(machine_id) when is_binary(machine_id) do
    :ok = OpenAgents.Cluster.Registry.unregister(@registry, {:machine, machine_id})
    broadcast_presence(machine_id, :offline)
    :ok
  end

  @spec online?(String.t()) :: boolean()
  def online?(machine_id),
    do: OpenAgents.Cluster.Registry.lookup(@registry, {:machine, machine_id}) != []

  @spec request_probe(String.t()) :: {:ok, map()} | {:error, atom()}
  def request_probe(machine_id) do
    case OpenAgents.Cluster.Registry.lookup(@registry, {:machine, machine_id}) do
      [{channel_pid, _value} | _rest] ->
        request_id = Ecto.UUID.generate()
        monitor = Process.monitor(channel_pid)
        send(channel_pid, {:computer_request, :probe, request_id, self()})

        receive do
          {:computer_response, ^request_id, {:ok, report}} ->
            Process.demonitor(monitor, [:flush])
            {:ok, report}

          {:computer_response, ^request_id, {:error, reason}} ->
            Process.demonitor(monitor, [:flush])
            {:error, reason}

          {:DOWN, ^monitor, :process, _pid, _reason} ->
            {:error, :machine_disconnected}
        after
          @probe_timeout_ms ->
            Process.demonitor(monitor, [:flush])
            {:error, :machine_timeout}
        end

      [] ->
        {:error, :machine_offline}
    end
  end

  @doc """
  Runs one argv-array command on the machine and collects its streamed output.

  The controller's local policy decides whether the command runs at all; a
  denial comes back as `{:refused, reason, detail}`. Output is collected
  bounded and the result carries the typed exit payload from the controller.
  """
  @spec request_run(String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:refused, String.t(), String.t()} | {:error, atom()}
  def request_run(machine_id, payload, timeout_ms \\ @run_timeout_ms) do
    streamed_request(machine_id, :run, payload, timeout_ms)
  end

  @doc """
  Delegates a prompt to a named ACP coding agent on the machine.

  The payload carries `agent_id` naming the agent the controller should run,
  plus `prompt` and optional `cwd`, `resume_session_id`, and `timeout_ms`.
  Streamed agent progress is collected bounded; the terminal payload carries
  the typed status (`completed`, `refused`, `cancelled`, `timeout`,
  `unavailable`, `failed`), the ACP session id, and the stop reason.
  """
  @spec request_agent(String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:refused, String.t(), String.t()} | {:error, atom()}
  def request_agent(machine_id, payload, timeout_ms \\ @agent_timeout_ms, opts \\ []) do
    streamed_request(machine_id, :agent, payload, timeout_ms, opts)
  end

  @doc """
  Deprecated: use `request_agent/3` with `agent_id` `"devin"`.

  Kept for one release; it delegates to the generic agent request, renaming
  the legacy `session_id` payload key to `resume_session_id`.
  """
  @spec request_devin(String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:refused, String.t(), String.t()} | {:error, atom()}
  def request_devin(machine_id, payload, timeout_ms \\ @agent_timeout_ms) do
    payload =
      payload
      |> Map.put("agent_id", "devin")
      |> rename_legacy_session_key()

    request_agent(machine_id, payload, timeout_ms)
  end

  defp rename_legacy_session_key(%{"session_id" => session_id} = payload) do
    payload |> Map.delete("session_id") |> Map.put("resume_session_id", session_id)
  end

  defp rename_legacy_session_key(payload), do: payload

  defp streamed_request(machine_id, kind, payload, timeout_ms, opts \\ []) do
    on_session = Keyword.get(opts, :on_session, fn _session_id -> :ok end)
    await_ms = Keyword.get(opts, :await_machine_ms, 0)

    case await_machine(machine_id, await_ms) do
      [{channel_pid, _value} | _rest] ->
        request_id = Ecto.UUID.generate()
        live = ComputerActivity.begin(machine_id, kind, request_id, payload)
        monitor = Process.monitor(channel_pid)
        send(channel_pid, {:computer_request, kind, request_id, payload, self()})
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        result = collect(request_id, monitor, deadline, [], 0, live, on_session)

        with {:timeout, partial_output} <- result do
          send(channel_pid, {:computer_cancel, request_id})

          {:ok,
           %{
             "status" => "timeout",
             "detail" =>
               "No completion within #{div(timeout_ms, 1000)}s; the job was cancelled. " <>
                 "Partial output up to that point is included.",
             "output" => partial_output,
             "truncated" => true
           }}
        end

      [] ->
        {:error, :machine_offline}
    end
  end

  # After a node loss the controller needs a moment to reconnect (through the
  # fleet LB, to a survivor) and re-register before a relocated delegation can
  # find it — worst case bounded by node-death detection (net_ticktime) plus the
  # controller's reconnect loop. A zero budget (the default) is a plain lookup.
  defp await_machine(machine_id, await_ms) do
    deadline = System.monotonic_time(:millisecond) + await_ms

    case OpenAgents.Cluster.Registry.lookup(@registry, {:machine, machine_id}) do
      [] = missing ->
        if System.monotonic_time(:millisecond) >= deadline do
          missing
        else
          Process.sleep(1_000)
          await_machine(machine_id, deadline - System.monotonic_time(:millisecond))
        end

      found ->
        found
    end
  end

  # A misbehaving on_session callback must never take down the delegation.
  defp safe_on_session(on_session, session_id) do
    on_session.(session_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp collect(request_id, monitor, deadline, chunks, collected_bytes, live, on_session) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      # The ACP session id arrived mid-stream — hand it to the caller (which
      # checkpoints it in Ra for re-attach) and keep collecting.
      {:computer_session, ^request_id, session_id} when is_binary(session_id) ->
        _ = safe_on_session(on_session, session_id)
        collect(request_id, monitor, deadline, chunks, collected_bytes, live, on_session)

      {:computer_chunk, ^request_id, text} when is_binary(text) ->
        if collected_bytes >= @maximum_collected_bytes do
          collect(
            request_id,
            monitor,
            deadline,
            chunks,
            collected_bytes,
            ComputerActivity.truncated(live),
            on_session
          )
        else
          kept =
            binary_part(text, 0, min(byte_size(text), @maximum_collected_bytes - collected_bytes))

          collect(
            request_id,
            monitor,
            deadline,
            [kept | chunks],
            collected_bytes + byte_size(kept),
            ComputerActivity.chunk(live, kept),
            on_session
          )
        end

      {:computer_response, ^request_id, {:ok, exit_payload}} ->
        Process.demonitor(monitor, [:flush])
        _projection = ComputerActivity.finish(live, exit_status(exit_payload), exit_payload)
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> valid_utf8()
        {:ok, Map.put(exit_payload, "output", output)}

      {:computer_response, ^request_id, {:refused, reason, detail}} ->
        Process.demonitor(monitor, [:flush])
        _projection = ComputerActivity.finish(live, "refused", nil)
        {:refused, reason, detail}

      {:computer_response, ^request_id, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        _projection = ComputerActivity.finish(live, Atom.to_string(reason), nil)
        {:error, reason}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        _projection = ComputerActivity.finish(live, "machine_disconnected", nil)
        {:error, :machine_disconnected}
    after
      remaining ->
        Process.demonitor(monitor, [:flush])
        _projection = ComputerActivity.finish(live, "timeout", nil)
        partial = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> valid_utf8()
        {:timeout, partial}
    end
  end

  defp exit_status(%{"status" => status}) when is_binary(status), do: status
  defp exit_status(_exit_payload), do: "completed"

  defp valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
    end
  end

  defp broadcast_presence(machine_id, presence) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      machine_topic(machine_id),
      {:computer_presence, machine_id, presence}
    )
  end

  defp machine_topic(machine_id), do: "machine:#{machine_id}"
end
