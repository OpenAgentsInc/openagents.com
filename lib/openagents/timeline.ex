defmodule OpenAgents.Timeline do
  @moduledoc """
  Owner-scoped, read-only merge of timeline entries across an account's
  coder/threads, voice sessions, and web chat.

  Every entry is rooted in the account's visitor, so a caller can see only
  records the account already owns. Thread transcripts are included only for
  threads the account opened; `dark` threads therefore stay visible only to
  their owner (THREAD-002).
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.{Conversation, ToolStep, Turn, Visitor}
  alias OpenAgents.Repo
  alias OpenAgents.Threads.{Event, Thread}
  alias OpenAgents.Voice.{Session, TranscriptItem}
  alias OpenAgents.Voice.ToolStep, as: VoiceToolStep

  @enforce_keys [:modality, :timestamp, :kind, :record_id, :summary]
  defstruct [:modality, :timestamp, :kind, :record_id, :summary, metadata: %{}]

  @type t :: %__MODULE__{
          modality: :voice | :coder | :chat,
          timestamp: DateTime.t() | nil,
          kind: :turn | :tool_step | :decision | :system,
          record_id: term(),
          summary: String.t(),
          metadata: map()
        }

  @doc """
  Returns the account's timeline, oldest first, with a documented tie-break.

  The sort key is `{timestamp, modality rank, record_id, kind rank}`. Rows
  without an event timestamp are ordered as though they occurred at the Unix
  epoch start, which is deterministic and monotonic.
  """
  @spec for_user(User.t()) :: [t()]
  def for_user(%User{id: user_id}) do
    case Repo.get_by(Visitor, user_id: user_id) do
      %Visitor{id: visitor_id} ->
        [thread_entries(visitor_id), voice_entries(visitor_id), chat_entries(visitor_id)]
        |> Enum.concat()
        |> Enum.sort_by(&entry_sort_key/1)

      nil ->
        []
    end
  end

  defp entry_sort_key(%__MODULE__{timestamp: nil} = entry) do
    {sentinel_timestamp(), modality_rank(entry.modality), entry.record_id, kind_rank(entry.kind)}
  end

  defp entry_sort_key(%__MODULE__{timestamp: ts} = entry) do
    {ts, modality_rank(entry.modality), entry.record_id, kind_rank(entry.kind)}
  end

  defp modality_rank(:coder), do: 0
  defp modality_rank(:voice), do: 1
  defp modality_rank(:chat), do: 2

  defp kind_rank(:turn), do: 0
  defp kind_rank(:tool_step), do: 1
  defp kind_rank(:decision), do: 2
  defp kind_rank(:system), do: 3

  defp sentinel_timestamp do
    DateTime.from_naive!(~N[1970-01-01 00:00:00], "Etc/UTC")
  end

  # Coder/threads
  defp thread_entries(visitor_id) do
    thread_ids =
      from(t in Thread, where: t.owner_visitor_id == ^visitor_id, select: t.id)
      |> Repo.all()

    from(e in Event,
      where: e.thread_id in ^thread_ids,
      order_by: [asc: e.emitted_at, asc: e.id]
    )
    |> Repo.all()
    |> Enum.map(&thread_entry/1)
  end

  defp thread_entry(%Event{} = event) do
    %__MODULE__{
      modality: :coder,
      timestamp: event.emitted_at,
      kind: thread_event_kind(event.event_type),
      record_id: event.id,
      summary: thread_summary(event),
      metadata: %{event_type: event.event_type, thread_id: event.thread_id}
    }
  end

  defp thread_event_kind("thread.opened"), do: :system
  defp thread_event_kind("thread.visibility_set"), do: :system
  defp thread_event_kind("thread.turn." <> _), do: :turn
  defp thread_event_kind("tool." <> _), do: :tool_step
  defp thread_event_kind(_), do: :decision

  defp thread_summary(%Event{event_type: event_type, payload: payload}) do
    case event_type do
      "tool.ran" ->
        "Tool ran: #{payload["tool"] || event_type}"

      "thread.opened" ->
        "Thread opened"

      "thread.visibility_set" ->
        "Thread visibility changed"

      _ ->
        humanize_event_type(event_type)
    end
  end

  defp humanize_event_type(event_type) do
    event_type
    |> String.replace(".", " ")
    |> String.capitalize()
  end

  # Voice
  defp voice_entries(visitor_id) do
    conversation_ids =
      from(c in Conversation, where: c.visitor_id == ^visitor_id, select: c.id)
      |> Repo.all()

    session_ids =
      from(s in Session, where: s.conversation_id in ^conversation_ids, select: s.id)
      |> Repo.all()

    transcript_items =
      from(ti in TranscriptItem, where: ti.voice_session_id in ^session_ids)
      |> Repo.all()
      |> Enum.map(&voice_transcript_entry/1)

    tool_steps =
      from(ts in VoiceToolStep, where: ts.voice_session_id in ^session_ids)
      |> Repo.all()
      |> Enum.map(&voice_tool_step_entry/1)

    transcript_items ++ tool_steps
  end

  defp voice_transcript_entry(%TranscriptItem{} = item) do
    %__MODULE__{
      modality: :voice,
      timestamp: item.observed_at,
      kind: :turn,
      record_id: item.id,
      summary: "Voice #{item.role}: #{shorten(TranscriptItem.text(item))}",
      metadata: %{
        role: item.role,
        status: item.status,
        voice_session_id: item.voice_session_id
      }
    }
  end

  defp voice_tool_step_entry(%VoiceToolStep{} = step) do
    %__MODULE__{
      modality: :voice,
      timestamp: step.requested_at,
      kind: :tool_step,
      record_id: step.id,
      summary: "Voice tool #{step.tool_name} (#{step.status})",
      metadata: %{
        tool_name: step.tool_name,
        status: step.status,
        voice_session_id: step.voice_session_id
      }
    }
  end

  # Web chat
  defp chat_entries(visitor_id) do
    conversation_ids =
      from(c in Conversation, where: c.visitor_id == ^visitor_id, select: c.id)
      |> Repo.all()

    turns =
      from(t in Turn, where: t.conversation_id in ^conversation_ids, preload: [:user_message])
      |> Repo.all()
      |> Enum.map(&chat_turn_entry/1)

    tool_steps =
      from(ts in ToolStep,
        join: t in Turn,
        on: t.id == ts.turn_id,
        where: t.conversation_id in ^conversation_ids
      )
      |> Repo.all()
      |> Enum.map(&chat_tool_step_entry/1)

    turns ++ tool_steps
  end

  defp chat_turn_entry(%Turn{} = turn) do
    content = if turn.user_message, do: turn.user_message.content, else: ""
    timestamp = turn.started_at || turn.inserted_at

    %__MODULE__{
      modality: :chat,
      timestamp: timestamp,
      kind: :turn,
      record_id: turn.id,
      summary: "Chat: #{shorten(content)}",
      metadata: %{
        status: turn.status,
        conversation_id: turn.conversation_id
      }
    }
  end

  defp chat_tool_step_entry(%ToolStep{} = step) do
    %__MODULE__{
      modality: :chat,
      timestamp: step.requested_at,
      kind: :tool_step,
      record_id: step.id,
      summary: "Tool #{step.tool_name} (#{step.status})",
      metadata: %{
        tool_name: step.tool_name,
        status: step.status,
        side_effect_class: step.side_effect_class
      }
    }
  end

  defp shorten(content) when is_binary(content) do
    if String.length(content) > 80,
      do: String.slice(content, 0, 80) <> "…",
      else: content
  end

  defp shorten(_content), do: ""
end
