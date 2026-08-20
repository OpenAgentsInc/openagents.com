defmodule OpenAgents.Voice.TestSidebandProvider do
  @behaviour OpenAgents.Voice.SidebandProvider

  @impl true
  def start_link(owner, session, _config) do
    process = spawn_link(fn -> loop(owner) end)

    if observer = Application.get_env(:openagents, :voice_sideband_test_observer) do
      send(observer, {:sideband_started, process, session})
    end

    send(owner, {:voice_sideband_connected, session.id, session.generation, process})
    {:ok, process}
  end

  @impl true
  def send_event(process, event) do
    send(process, {:send_event, event})
    :ok
  end

  @impl true
  def close(process) do
    send(process, :close)
    :ok
  end

  defp loop(owner) do
    receive do
      {:send_event, event} ->
        if observer = Application.get_env(:openagents, :voice_sideband_test_observer) do
          send(observer, {:sideband_event_sent, event})
        end

        loop(owner)

      {:provider_event, session, event} ->
        send(owner, {:voice_provider_event, session.id, session.generation, event})
        loop(owner)

      :disconnect ->
        send(owner, :test_sideband_disconnected)

      :close ->
        :ok
    end
  end
end
