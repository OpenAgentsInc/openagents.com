defmodule OpenAgents.Admin.Call do
  @moduledoc """
  One voice call as the operator sees it.

  Unlike `OpenAgents.Leaderboard.Entry`, this projection is not published — exactly one
  identity can read it (`INVARIANTS.md` ADMIN-001). It is still an explicit struct
  rather than a raw row, for two reasons:

    * a call carries private material (composed instructions, tool catalogs,
      provider call identity, transcript content) that the panel has no business
      rendering, and a whitelist is the only way to keep it that way; and
    * the recording fields say plainly how complete the audio is, so a partial
      upload is never presented as a whole call.
  """

  @enforce_keys [
    :session_id,
    :generation,
    :status,
    :model_id,
    :voice_artifact_id,
    :started_at,
    :ended_at,
    :termination_reason,
    :failure_code,
    :total_tokens,
    :github_login,
    :github_name,
    :github_avatar_url,
    :transcript_item_count,
    :recording
  ]

  defstruct @enforce_keys

  @type recording :: %{
          id: Ecto.UUID.t(),
          status: String.t(),
          container: String.t(),
          codec: String.t(),
          channel_layout: String.t(),
          sealed: boolean(),
          byte_size: non_neg_integer(),
          chunk_count: non_neg_integer(),
          client_duration_ms: non_neg_integer() | nil,
          completed_at: DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t(),
          generation: pos_integer(),
          status: String.t(),
          model_id: String.t(),
          voice_artifact_id: String.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          termination_reason: String.t() | nil,
          failure_code: String.t() | nil,
          total_tokens: non_neg_integer(),
          github_login: String.t(),
          github_name: String.t() | nil,
          github_avatar_url: String.t(),
          transcript_item_count: non_neg_integer(),
          recording: recording() | nil
        }

  @doc "Whether this call has audio the operator can play."
  @spec playable?(t()) :: boolean()
  def playable?(%__MODULE__{recording: %{chunk_count: count, status: status}})
      when count > 0,
      do: status in OpenAgents.Voice.Recording.playable_statuses()

  def playable?(%__MODULE__{}), do: false

  @doc """
  Why there is no audio, in the operator's terms.

  A panel that silently omits unrecorded calls looks like an empty history rather
  than an honest one, so every call is listed and the absence is explained.
  """
  @spec absence_reason(t()) :: String.t()
  def absence_reason(%__MODULE__{recording: nil}),
    do: "No audio uploaded. The call predates recording, or the browser never captured it."

  def absence_reason(%__MODULE__{recording: %{status: "failed"}}),
    do: "The browser reported that capture failed. Transcript evidence is unaffected."

  def absence_reason(%__MODULE__{recording: %{chunk_count: 0}}),
    do: "Recording opened but no audio arrived before the call ended."

  def absence_reason(%__MODULE__{}), do: "No audio available."

  @doc "How complete the uploaded audio is, in the operator's terms."
  @spec completeness(t()) :: String.t() | nil
  def completeness(%__MODULE__{recording: nil}), do: nil

  def completeness(%__MODULE__{recording: %{status: status}}) do
    case status do
      "complete" -> "Complete upload"
      "recording" -> "Upload in progress"
      "truncated" -> "Truncated at the size ceiling"
      "aborted" -> "Ended without a clean stop"
      "failed" -> "Capture failed"
      _other -> nil
    end
  end

  @doc "The display name to lead with, matching the account chrome."
  @spec display_name(t()) :: String.t() | nil
  def display_name(%__MODULE__{github_name: name}) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  def display_name(%__MODULE__{}), do: nil
end
