defmodule OpenAgents.ComputerActivity do
  @moduledoc """
  Ephemeral live projection of one streamed computer delegation.

  While `OpenAgents.Computer` collects a delegation's streamed output, this module
  re-broadcasts a bounded projection of the stream over PubSub on the computer
  owner's conversation topic — the delegation start, each bounded chunk, and
  the typed terminal — so the chat interface can show the remote agent working
  while it works. PubSub is a low-latency projection and never the data
  authority: nothing broadcast here is persisted, a missed broadcast loses
  nothing durable, and the durable record remains the terminal tool-step
  outcome. A reload mid-delegation degrades to status-only.

  The topic is owner-scoped by construction: Sarah is a one-conversation
  product, delegations require the `browser_conversation` scope of the computer
  owner, and the topic is keyed by that owner's conversation id, which only
  the owner's own LiveView subscribes to.

  Chunk text is the controller's already secret-scrubbed output, re-bounded
  here before it can reach a socket: at most `@maximum_event_bytes` per
  broadcast event, `@maximum_total_bytes` cumulative (mirroring the
  65,536-byte collection cap in `OpenAgents.Computer`), and at most
  `@maximum_chunk_events` chunk events per delegation. Once any cap is hit,
  one truncation event is broadcast and chunk broadcasting stops. Computer
  tokens, argv, env, prompts, and filesystem paths never enter an event.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repo

  @maximum_event_bytes 16_384
  @maximum_total_bytes 65_536
  @maximum_chunk_events 512

  @doc "Subscribes the caller to one conversation's live delegation projection."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic(conversation_id))
  end

  @doc false
  def topic(conversation_id), do: "computer_live:#{conversation_id}"

  @doc """
  Opens the projection for one delegation and broadcasts its start event.

  Returns projection state to thread through the collect loop, or `nil` when
  the computer's owning conversation cannot be resolved — every later call is
  then a no-op and the delegation runs exactly as before, unprojected.
  """
  @spec begin(String.t(), :run | :agent, String.t(), map()) :: map() | nil
  def begin(machine_id, kind, ref, payload) when kind in [:run, :agent] do
    with %Machine{} = machine <- Repo.get(Machine, machine_id),
         %{id: conversation_id} <-
           Conversations.get_conversation_for_user(%User{id: machine.user_id}) do
      state = %{
        topic: topic(conversation_id),
        ref: ref,
        seq: 0,
        sent_bytes: 0,
        halted: false,
        started_at_monotonic: System.monotonic_time(:millisecond)
      }

      broadcast(state, {
        :computer_live_started,
        %{
          ref: ref,
          kind: Atom.to_string(kind),
          machine_id: machine.id,
          machine_name: bounded(machine.name, 80),
          agent_id: bounded(payload["agent_id"], 64),
          started_at: DateTime.utc_now()
        }
      })

      state
    else
      _unresolved_owner -> nil
    end
  end

  @doc """
  Broadcasts one bounded chunk event, enforcing the per-event, cumulative,
  and event-count caps. Once a cap is hit, `truncated/1` fires instead and the
  projection halts for the rest of the delegation.
  """
  @spec chunk(map() | nil, binary()) :: map() | nil
  def chunk(nil, _text), do: nil
  def chunk(%{halted: true} = state, _text), do: state

  def chunk(state, text) when is_binary(text) do
    remaining = @maximum_total_bytes - state.sent_bytes

    if remaining <= 0 or state.seq >= @maximum_chunk_events do
      truncated(state)
    else
      kept =
        text
        |> binary_part(0, Enum.min([byte_size(text), remaining, @maximum_event_bytes]))
        |> valid_utf8()

      seq = state.seq + 1
      broadcast(state, {:computer_live_chunk, %{ref: state.ref, seq: seq, text: kept}})
      %{state | seq: seq, sent_bytes: state.sent_bytes + byte_size(kept)}
    end
  end

  @doc "Broadcasts the one truncation marker and halts further chunk events."
  @spec truncated(map() | nil) :: map() | nil
  def truncated(nil), do: nil
  def truncated(%{halted: true} = state), do: state

  def truncated(state) do
    broadcast(state, {:computer_live_truncated, %{ref: state.ref}})
    %{state | halted: true}
  end

  @doc """
  Broadcasts the typed terminal event: the controller-reported (or
  Sarah-typed) status word, the bounded stop reason, and the duration —
  controller-reported when present, otherwise measured here.
  """
  @spec finish(map() | nil, String.t(), map() | nil) :: nil
  def finish(nil, _status, _exit_payload), do: nil

  def finish(state, status, exit_payload) do
    exit_payload = if is_map(exit_payload), do: exit_payload, else: %{}

    duration_ms =
      case exit_payload["duration_ms"] do
        milliseconds when is_integer(milliseconds) and milliseconds >= 0 ->
          milliseconds

        _unreported ->
          System.monotonic_time(:millisecond) - state.started_at_monotonic
      end

    broadcast(state, {
      :computer_live_terminal,
      %{
        ref: state.ref,
        status: bounded(status, 32),
        stop_reason: bounded(exit_payload["stop_reason"], 32),
        duration_ms: duration_ms
      }
    })

    nil
  end

  defp broadcast(%{topic: topic}, event) do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, topic, event)
  end

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded(_value, _maximum), do: ""

  defp valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
    end
  end
end
