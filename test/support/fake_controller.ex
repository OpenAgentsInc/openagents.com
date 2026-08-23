defmodule OpenAgents.Support.FakeController do
  @moduledoc """
  Stands in for a connected controller channel process in tests.

  It registers under a machine id exactly as `OpenAgentsWeb.ComputerChannel` does and
  answers `:computer_request` messages from a scripted reply, so the server-side
  request/streaming/cancellation paths can be exercised without a real machine.
  """

  use GenServer

  @doc """
  Starts a fake controller for `machine_id`.

  `:script` is a function receiving `{kind, request_id, payload, caller}` and is
  responsible for sending chunks and one terminal reply. `chunk/3`, `exit/3`,
  `refused/4` build those messages.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec chunk(pid(), String.t(), String.t()) :: :ok
  def chunk(caller, request_id, text) do
    send(caller, {:computer_chunk, request_id, text})
    :ok
  end

  @spec exit(pid(), String.t(), map()) :: :ok
  def exit(caller, request_id, payload) do
    send(caller, {:computer_response, request_id, {:ok, payload}})
    :ok
  end

  @spec refused(pid(), String.t(), String.t(), String.t()) :: :ok
  def refused(caller, request_id, reason, detail) do
    send(caller, {:computer_response, request_id, {:refused, reason, detail}})
    :ok
  end

  @impl true
  def init(options) do
    machine_id = Keyword.fetch!(options, :machine_id)
    {:ok, _owner} = OpenAgents.Computer.register(machine_id)

    {:ok,
     %{
       machine_id: machine_id,
       script: Keyword.fetch!(options, :script),
       observer: Keyword.get(options, :observer)
     }}
  end

  @impl true
  def handle_info({:computer_request, kind, request_id, payload, caller}, state) do
    state.script.({kind, request_id, payload, caller})
    {:noreply, state}
  end

  def handle_info({:computer_request, kind, request_id, caller}, state) do
    state.script.({kind, request_id, %{}, caller})
    {:noreply, state}
  end

  def handle_info({:computer_cancel, _request_id} = message, state) do
    if is_pid(state.observer), do: send(state.observer, message)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    OpenAgents.Computer.unregister(state.machine_id)
  end
end
