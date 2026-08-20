defmodule OpenAgentsWeb.ComputerChannel do
  @moduledoc """
  `openagents.computer.v1` — the live channel a paired controller keeps open.

  Server to controller: `probe`, `run`, `agent`, `devin`, and `cancel` (each correlated
  by a server-minted `request_id`). Controller to server: `hello` (agent
  version, tier, roots, platform, probe report), `probe_result`, streamed
  `chunk` events, one terminal `exit`, or `refused` when local policy denies a
  request. Every inbound payload is bounded before it touches the database, and
  a revoked machine is disconnected immediately.
  """

  use Phoenix.Channel

  alias OpenAgents.Computer
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine

  @maximum_payload_bytes 65_536

  @impl true
  def join("computer:" <> machine_id, _payload, socket) do
    if machine_id == socket.assigns.machine_id do
      case Machines.get_machine(socket.assigns.user_id, machine_id) do
        {:ok, %Machine{status: "active"} = machine} ->
          case Computer.register(machine.id) do
            {:ok, _owner} ->
              Phoenix.PubSub.subscribe(OpenAgents.PubSub, "machine:#{machine.id}")
              Machines.record_seen(machine)
              schedule_token_expiry(socket.assigns.token_expires_at, machine.id)
              {:ok, %{"protocol" => "openagents.computer.v1"}, assign(socket, :machine, machine)}

            # A prior registration (usually from a node that just died) hasn't
            # been pruned yet — refuse the join; the controller's reconnect
            # loop retries until the cluster clears it (bounded by
            # net_ticktime).
            {:error, :already_registered} ->
              {:error, %{"reason" => "machine_reconnecting"}}
          end

        _revoked_or_missing ->
          {:error, %{"reason" => "machine_unavailable"}}
      end
    else
      {:error, %{"reason" => "machine_mismatch"}}
    end
  end

  @impl true
  def handle_in("hello", payload, socket) do
    with :ok <- verify_bounded(payload),
         {:ok, machine} <- store_report(socket, Map.get(payload, "probe")) do
      {:reply, {:ok, %{"machine" => summary(machine)}}, assign(socket, :machine, machine)}
    else
      {:error, reason} -> {:reply, {:error, %{"reason" => Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("probe_result", %{"request_id" => request_id} = payload, socket)
      when is_binary(request_id) do
    with :ok <- verify_bounded(payload),
         %{} = report <- Map.get(payload, "probe"),
         {:ok, machine} <- Machines.store_probe(socket.assigns.machine, report) do
      {:noreply, socket |> respond(request_id, {:ok, report}) |> assign(:machine, machine)}
    else
      _invalid ->
        {:noreply, respond(socket, request_id, {:error, :invalid_probe_report})}
    end
  end

  def handle_in("probe_refused", %{"request_id" => request_id}, socket)
      when is_binary(request_id) do
    {:noreply, respond(socket, request_id, {:error, :machine_refused})}
  end

  def handle_in("chunk", %{"request_id" => request_id, "text" => text} = payload, socket)
      when is_binary(request_id) and is_binary(text) do
    with :ok <- verify_bounded(payload),
         pid when is_pid(pid) <- Map.get(Map.get(socket.assigns, :pending, %{}), request_id) do
      send(pid, {:computer_chunk, request_id, text})
    end

    {:noreply, socket}
  end

  # The controller reports the ACP session id as soon as `session/new` returns —
  # mid-stream, not just in the terminal `exit`. This is what lets the server
  # checkpoint the id (in Ra) while the delegation is still running, so a
  # survivor can re-attach to the live ACP session by id after a node dies (M2).
  def handle_in("session", %{"request_id" => request_id, "session_id" => session_id}, socket)
      when is_binary(request_id) and is_binary(session_id) do
    with pid when is_pid(pid) <- Map.get(Map.get(socket.assigns, :pending, %{}), request_id) do
      send(pid, {:computer_session, request_id, session_id})
    end

    {:noreply, socket}
  end

  def handle_in("exit", %{"request_id" => request_id} = payload, socket)
      when is_binary(request_id) do
    case verify_bounded(payload) do
      :ok ->
        {:noreply, respond(socket, request_id, {:ok, Map.delete(payload, "request_id")})}

      {:error, reason} ->
        {:noreply, respond(socket, request_id, {:error, reason})}
    end
  end

  def handle_in("refused", %{"request_id" => request_id} = payload, socket)
      when is_binary(request_id) do
    reason = bounded_text(Map.get(payload, "reason"), 64, "policy_refused")
    detail = bounded_text(Map.get(payload, "detail"), 500, "")
    {:noreply, respond(socket, request_id, {:refused, reason, detail})}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{"reason" => "unknown_event"}}, socket}
  end

  @impl true
  def handle_info({:computer_request, :probe, request_id, from}, socket) do
    push(socket, "probe", %{"request_id" => request_id})
    {:noreply, track(socket, request_id, from)}
  end

  def handle_info({:computer_request, kind, request_id, payload, from}, socket)
      when kind in [:run, :devin, :agent] do
    push(socket, Atom.to_string(kind), Map.put(payload, "request_id", request_id))
    {:noreply, track(socket, request_id, from)}
  end

  def handle_info({:computer_cancel, request_id}, socket) do
    push(socket, "cancel", %{"request_id" => request_id})
    {:noreply, forget(socket, request_id)}
  end

  # The caller that started this request died before its terminal reply — the
  # turn was stopped or timed out while a delegation was still streaming. The
  # controller has no other way to learn, so push a cancel for the orphaned
  # request_id (killing the ACP subprocess) rather than letting it run to its
  # own timeout while nothing is listening. This is what makes the composer's
  # Stop actually stop a long computer delegation.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Map.get(Map.get(socket.assigns, :monitors, %{}), ref) do
      request_id when is_binary(request_id) ->
        push(socket, "cancel", %{"request_id" => request_id})
        {:noreply, forget(socket, request_id)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:machine_revoked, _machine_id}, socket) do
    {:stop, :normal, socket}
  end

  def handle_info(
        {:machine_token_expired, machine_id},
        %{assigns: %{machine_id: machine_id}} = socket
      ) do
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :machine) do
      %Machine{id: machine_id} -> Computer.unregister(machine_id)
      _not_joined -> :ok
    end

    :ok
  end

  # Record the in-flight request and monitor its caller so a caller that dies
  # (a stopped or failed turn) triggers a controller-side cancel via :DOWN.
  defp track(socket, request_id, from) do
    ref = Process.monitor(from)
    pending = Map.get(socket.assigns, :pending, %{})
    monitors = Map.get(socket.assigns, :monitors, %{})
    refs = Map.get(socket.assigns, :refs, %{})

    socket
    |> assign(:pending, Map.put(pending, request_id, from))
    |> assign(:monitors, Map.put(monitors, ref, request_id))
    |> assign(:refs, Map.put(refs, request_id, ref))
  end

  # Drop an in-flight request and stop monitoring its caller.
  defp forget(socket, request_id) do
    pending = Map.get(socket.assigns, :pending, %{})
    monitors = Map.get(socket.assigns, :monitors, %{})
    refs = Map.get(socket.assigns, :refs, %{})

    monitors =
      case Map.get(refs, request_id) do
        ref when is_reference(ref) ->
          Process.demonitor(ref, [:flush])
          Map.delete(monitors, ref)

        nil ->
          monitors
      end

    socket
    |> assign(:pending, Map.delete(pending, request_id))
    |> assign(:monitors, monitors)
    |> assign(:refs, Map.delete(refs, request_id))
  end

  defp respond(socket, request_id, response) do
    pending = Map.get(socket.assigns, :pending, %{})

    case Map.get(pending, request_id) do
      pid when is_pid(pid) -> send(pid, {:computer_response, request_id, response})
      nil -> :ok
    end

    forget(socket, request_id)
  end

  defp bounded_text(value, maximum, _fallback) when is_binary(value),
    do: String.slice(value, 0, maximum)

  defp bounded_text(_value, _maximum, fallback), do: fallback

  defp schedule_token_expiry(expires_at, machine_id) do
    delay_ms = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:machine_token_expired, machine_id}, delay_ms)
  end

  defp store_report(socket, report) when is_map(report),
    do: Machines.store_probe(socket.assigns.machine, report)

  defp store_report(socket, _absent), do: {:ok, socket.assigns.machine}

  defp verify_bounded(payload) do
    if byte_size(Jason.encode!(payload)) <= @maximum_payload_bytes,
      do: :ok,
      else: {:error, :payload_too_large}
  end

  defp summary(%Machine{} = machine) do
    %{
      "id" => machine.id,
      "name" => machine.name,
      "tier" => machine.tier,
      "platform" => machine.platform
    }
  end
end
