defmodule OpenAgents.Admin do
  @moduledoc """
  Read-only cross-account reads for the operator surface.

  IDENTITY-002 confines every ordinary server path to the active user's own data.
  This module is the second deliberate exception after `OpenAgents.Leaderboard`, and it
  differs from that one in both directions: it reads far more per call, and it is
  readable by exactly one identity rather than by the internet
  (`INVARIANTS.md` ADMIN-001).

  Nothing here writes. The operator listens and reads; there is no ban control,
  no message injection, no deletion, and no configuration change on this path, so
  a mistake in the surface cannot alter anyone's conversation.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Admin.Call
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Repo
  alias OpenAgents.Voice.Recording
  alias OpenAgents.Voice.Session
  alias OpenAgents.Voice.TranscriptItem

  @default_limit 50
  @maximum_limit 200

  @doc """
  Voice calls newest first, across every account.

  Calls without audio are included on purpose — see `OpenAgents.Admin.Call`.
  """
  @spec list_calls(keyword()) :: [Call.t()]
  def list_calls(options \\ []) do
    limit = options |> Keyword.get(:limit, @default_limit) |> bound_limit()
    offset = options |> Keyword.get(:offset, 0) |> max(0)

    from(session in Session,
      join: conversation in Conversation,
      on: conversation.id == session.conversation_id,
      join: visitor in Visitor,
      on: visitor.id == conversation.visitor_id,
      join: user in User,
      on: user.id == visitor.user_id,
      left_join: recording in Recording,
      on: recording.voice_session_id == session.id and recording.generation == session.generation,
      left_join: transcript in subquery(transcript_counts()),
      on: transcript.voice_session_id == session.id,
      order_by: [desc: session.started_at, desc: session.id],
      limit: ^limit,
      offset: ^offset,
      select: %{
        session_id: session.id,
        generation: session.generation,
        status: session.status,
        model_id: session.model_id,
        voice_artifact_id: session.voice_artifact_id,
        started_at: session.started_at,
        ended_at: session.ended_at,
        termination_reason: session.termination_reason,
        failure_code: session.failure_code,
        usage: session.usage,
        github_login: user.github_login,
        github_name: user.github_name,
        github_avatar_url: user.github_avatar_url,
        transcript_item_count: transcript.count,
        recording_id: recording.id,
        recording_status: recording.status,
        recording_container: recording.container,
        recording_codec: recording.codec,
        recording_channel_layout: recording.channel_layout,
        recording_sealed: recording.sealed,
        recording_byte_size: recording.byte_size,
        recording_chunk_count: recording.chunk_count,
        recording_client_duration_ms: recording.client_duration_ms,
        recording_completed_at: recording.completed_at
      }
    )
    |> Repo.all()
    |> Enum.map(&to_call/1)
  end

  @doc "How many voice calls exist, for paging the panel honestly."
  @spec count_calls() :: non_neg_integer()
  def count_calls do
    Repo.aggregate(
      from(session in Session,
        join: conversation in Conversation,
        on: conversation.id == session.conversation_id,
        join: visitor in Visitor,
        on: visitor.id == conversation.visitor_id,
        join: user in User,
        on: user.id == visitor.user_id
      ),
      :count
    )
  end

  @doc """
  Totals for the panel header.

  Content-free counters: how many calls exist, how many carry audio, and how many
  bytes of audio are stored. Byte counts are operational, not content.
  """
  @spec recording_totals() :: %{
          calls: non_neg_integer(),
          recorded: non_neg_integer(),
          byte_size: non_neg_integer()
        }
  def recording_totals do
    %{byte_size: byte_size, recorded: recorded} =
      Repo.one(
        from(recording in Recording,
          where: recording.chunk_count > 0,
          select: %{
            byte_size: coalesce(sum(recording.byte_size), 0),
            recorded: count(recording.id)
          }
        )
      )

    # A sum over a bigint column comes back as a Decimal; the surface wants an
    # integer it can format.
    %{calls: count_calls(), recorded: recorded, byte_size: as_integer(byte_size)}
  end

  defp as_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp as_integer(value) when is_integer(value), do: value
  defp as_integer(_value), do: 0

  @doc """
  One recording, with the account it belongs to, for the audio reader.

  Returns `nil` rather than raising for a missing or malformed identifier: an
  operator following a stale link should get an honest 404, not a crash report.
  """
  @spec get_recording(Ecto.UUID.t()) ::
          {:ok, Recording.t(), %{github_login: String.t(), session_id: Ecto.UUID.t()}}
          | {:error, :not_found}
  def get_recording(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{recording: %Recording{} = recording} = row <- recording_row(uuid) do
      {:ok, recording, %{github_login: row.github_login, session_id: recording.voice_session_id}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def get_recording(_id), do: {:error, :not_found}

  defp recording_row(uuid) do
    Repo.one(
      from(recording in Recording,
        join: session in Session,
        on: session.id == recording.voice_session_id,
        join: conversation in Conversation,
        on: conversation.id == session.conversation_id,
        join: visitor in Visitor,
        on: visitor.id == conversation.visitor_id,
        join: user in User,
        on: user.id == visitor.user_id,
        where: recording.id == ^uuid,
        select: %{recording: recording, github_login: user.github_login}
      )
    )
  end

  defp to_call(row) do
    %Call{
      session_id: row.session_id,
      generation: row.generation,
      status: row.status,
      model_id: row.model_id,
      voice_artifact_id: row.voice_artifact_id,
      started_at: row.started_at,
      ended_at: row.ended_at,
      termination_reason: row.termination_reason,
      failure_code: row.failure_code,
      total_tokens: total_tokens(row.usage),
      github_login: row.github_login,
      github_name: row.github_name,
      github_avatar_url: row.github_avatar_url,
      transcript_item_count: row.transcript_item_count || 0,
      recording: recording_projection(row)
    }
  end

  defp recording_projection(%{recording_id: nil}), do: nil

  defp recording_projection(row) do
    %{
      id: row.recording_id,
      status: row.recording_status,
      container: row.recording_container,
      codec: row.recording_codec,
      channel_layout: row.recording_channel_layout,
      sealed: row.recording_sealed,
      byte_size: row.recording_byte_size || 0,
      chunk_count: row.recording_chunk_count || 0,
      client_duration_ms: row.recording_client_duration_ms,
      completed_at: row.recording_completed_at
    }
  end

  # Voice usage always carries `total_tokens`, but a provider adapter that omits
  # it should read as the sum it did report rather than as zero.
  defp total_tokens(usage) when is_map(usage) do
    case usage do
      %{"total_tokens" => total} when is_integer(total) and total >= 0 ->
        total

      %{"input_tokens" => input, "output_tokens" => output}
      when is_integer(input) and is_integer(output) ->
        max(input, 0) + max(output, 0)

      _absent ->
        0
    end
  end

  defp total_tokens(_usage), do: 0

  defp bound_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @maximum_limit)
  defp bound_limit(_limit), do: @default_limit

  # Only the count, never the content: the panel says whether a transcript exists
  # so the operator can tell a silent call from an unrecorded one, and reads the
  # transcript itself nowhere.
  defp transcript_counts do
    from(item in TranscriptItem,
      group_by: item.voice_session_id,
      select: %{voice_session_id: item.voice_session_id, count: count(item.id)}
    )
  end
end
