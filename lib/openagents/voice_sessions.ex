defmodule OpenAgents.VoiceSessions do
  @moduledoc "Supervised entry point for admitting and controlling live voice sessions."

  alias OpenAgents.Conversations.{Conversation, Message}
  alias OpenAgents.Voice
  alias OpenAgents.Voice.{CallAdmission, Config, Session}
  alias OpenAgents.VoiceSessions.SessionServer

  @spec connect(Conversation.t(), String.t(), String.t(), Config.t()) ::
          {:ok, Session.t(), CallAdmission.t()} | {:error, term()}
  def connect(
        %Conversation{} = conversation,
        sdp_offer,
        safety_identifier,
        %Config{} = config
      ) do
    with {:ok, session} <- Voice.admit_session(conversation, config),
         {:ok, process} <- start(session.id) do
      try do
        case GenServer.call(process, {:connect, sdp_offer, safety_identifier}, 35_000) do
          {:ok, %CallAdmission{} = admission} ->
            {:ok, Voice.get_session!(session.id), admission}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, _reason ->
          _failure_result = Voice.fail_session(session, session.generation, :connect_timeout)
          {:error, :voice_connection_failed}
      end
    end
  end

  @spec start(Ecto.UUID.t()) :: DynamicSupervisor.on_start_child()
  def start(session_id) do
    DynamicSupervisor.start_child(OpenAgents.VoiceSessionSupervisor, {SessionServer, session_id})
  end

  @spec end_session(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def end_session(%Session{} = session, reason \\ "user_ended") do
    case whereis(session.id) do
      nil -> Voice.end_session(session, session.generation, reason)
      process -> GenServer.call(process, {:end_session, reason})
    end
  end

  @spec interrupt_session(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def interrupt_session(%Session{} = session) do
    case whereis(session.id) do
      nil -> {:error, :voice_session_not_running}
      process -> GenServer.call(process, :interrupt_response)
    end
  end

  @doc """
  Adds a typed user message to the live provider conversation so voice Sarah
  can read it (links, code, exact text) without ending the call.
  """
  @spec inject_typed_message(Session.t(), Message.t()) :: :ok | {:error, term()}
  def inject_typed_message(%Session{} = session, %Message{} = message) do
    case whereis(session.id) do
      nil -> {:error, :voice_session_not_running}
      process -> GenServer.call(process, {:inject_typed_message, message.content})
    end
  end

  @spec send_control(Session.t(), map()) :: :ok | {:error, term()}
  def send_control(%Session{} = session, event) when is_map(event) do
    case whereis(session.id) do
      nil -> {:error, :voice_session_not_running}
      process -> GenServer.call(process, {:send_control, event})
    end
  end

  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(OpenAgents.VoiceSessionRegistry, session_id) do
      [{process, _value}] -> process
      [] -> nil
    end
  end
end
