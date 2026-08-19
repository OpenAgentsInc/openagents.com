defmodule OpenAgents.Voice.OpenAI.Sideband do
  @moduledoc "OpenAI Realtime server-side sideband WebSocket adapter."

  use WebSockex

  @behaviour OpenAgents.Voice.SidebandProvider

  alias OpenAgents.Voice.{Config, Session}
  alias OpenAgents.Voice.OpenAI.EventDecoder

  @endpoint "wss://api.openai.com/v1/realtime"

  @impl OpenAgents.Voice.SidebandProvider
  def start_link(owner, %Session{} = session, %Config{}) when is_pid(owner) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, call_id} <- validate_call_id(session.provider_session_id) do
      state = %{owner: owner, session_id: session.id, generation: session.generation}
      url = @endpoint <> "?call_id=" <> URI.encode_www_form(call_id)

      WebSockex.start_link(url, __MODULE__, state,
        extra_headers: [{"Authorization", "Bearer " <> api_key}]
      )
    end
  end

  @impl OpenAgents.Voice.SidebandProvider
  def send_event(sideband, event) when is_pid(sideband) and is_map(event) do
    WebSockex.cast(sideband, {:send_event, event})
    :ok
  end

  @impl OpenAgents.Voice.SidebandProvider
  def close(sideband) when is_pid(sideband) do
    WebSockex.cast(sideband, :close)
    :ok
  end

  @impl WebSockex
  def handle_connect(_connection, state) do
    send(state.owner, {:voice_sideband_connected, state.session_id, state.generation, self()})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, encoded}, state) do
    case Jason.decode(encoded) do
      {:ok, event} when is_map(event) ->
        case EventDecoder.decode(event) do
          {:ok, provider_event} ->
            send(
              state.owner,
              {:voice_provider_event, state.session_id, state.generation, provider_event}
            )

          :ignore ->
            :ok

          {:error, _reason} ->
            send(
              state.owner,
              {:voice_sideband_protocol_error, state.session_id, state.generation}
            )
        end

      {:error, _reason} ->
        send(state.owner, {:voice_sideband_protocol_error, state.session_id, state.generation})
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_cast({:send_event, event}, state) do
    {:reply, {:text, Jason.encode!(event)}, state}
  end

  def handle_cast(:close, state), do: {:close, state}
  def handle_cast(_message, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(_connection_status, state) do
    send(state.owner, {:voice_sideband_disconnected, state.session_id, state.generation})
    {:ok, state}
  end

  defp fetch_api_key do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp validate_call_id("rtc_" <> _rest = call_id) when byte_size(call_id) <= 256,
    do: {:ok, call_id}

  defp validate_call_id(_call_id), do: {:error, :invalid_call_id}
end
