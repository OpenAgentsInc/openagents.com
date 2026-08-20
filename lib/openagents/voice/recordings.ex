defmodule OpenAgents.Voice.Recordings do
  @moduledoc """
  Durable, generation-fenced authority for call audio.

  ## Why the browser uploads it

  Voice media never reaches OpenAgents. `OpenAgents.Voice.OpenAI.CallClient` brokers one
  SDP exchange and the audio then flows browser-to-OpenAI over WebRTC, with the
  server holding only a lifecycle sideband. There is no server-side frame to
  persist, so the browser mixes its microphone and Sarah's track into one stereo
  stream and uploads it in slices.

  That makes a recording *browser-supplied evidence*: a client can withhold,
  truncate or stop uploading at any point. It is never authority for what was
  said — `OpenAgents.Voice.TranscriptItem` stays the conversation record
  (`INVARIANTS.md` VOICE-004, VOICE-009, VOICE-012).

  ## What is bounded

  This is an endpoint that accepts bytes, so every dimension has a ceiling:
  chunk size, chunk count, and total bytes per recording, plus a grace window
  after the call ends. Past a ceiling the recording becomes `truncated` and
  further slices are refused; it never grows without limit.

  ## Ordering

  Slices are only media as an ordered concatenation, so appends are strictly
  sequential under a locked session row. A repeat of the sequence already stored
  is idempotent (a retried upload), a gap is refused, and a stale generation is
  refused the same way every other voice write is.
  """

  import Ecto.Query

  alias OpenAgents.Repo
  alias OpenAgents.Voice.{Recording, RecordingChunk, RecordingVault, Session}

  @content_types %{
    "audio/webm" => {"webm", "opus"},
    "audio/webm;codecs=opus" => {"webm", "opus"},
    "audio/ogg" => {"ogg", "opus"},
    "audio/ogg;codecs=opus" => {"ogg", "opus"},
    "audio/mp4" => {"mp4", "aac"},
    "audio/mp4;codecs=mp4a.40.2" => {"mp4", "aac"}
  }

  @terminal_session_statuses ~w(ended failed)

  @doc """
  Recording settings, with the vault taken into account.

  `enabled?` is false when no recording key is configured even if the flag is on:
  audio this sensitive is stored sealed or not at all, and the voice control row
  reads this so it cannot claim a call is recorded when it is not.
  """
  @spec config() :: %{
          enabled?: boolean(),
          sealed?: boolean(),
          timeslice_ms: pos_integer(),
          maximum_chunk_bytes: pos_integer(),
          maximum_chunks: pos_integer(),
          maximum_bytes: pos_integer(),
          late_chunk_grace_seconds: non_neg_integer(),
          retention_days: pos_integer()
        }
  def config do
    settings = Application.fetch_env!(:openagents, :voice_recording)
    sealed? = RecordingVault.configured?()

    %{
      enabled?: Keyword.fetch!(settings, :enabled) and sealed?,
      sealed?: sealed?,
      timeslice_ms: Keyword.fetch!(settings, :timeslice_ms),
      maximum_chunk_bytes: Keyword.fetch!(settings, :maximum_chunk_bytes),
      maximum_chunks: Keyword.fetch!(settings, :maximum_chunks),
      maximum_bytes: Keyword.fetch!(settings, :maximum_bytes),
      late_chunk_grace_seconds: Keyword.fetch!(settings, :late_chunk_grace_seconds),
      retention_days: Keyword.fetch!(settings, :retention_days)
    }
  end

  @doc "The media type a stored recording should be served as."
  @spec content_type(Recording.t()) :: String.t()
  def content_type(%Recording{container: "webm"}), do: "audio/webm"
  def content_type(%Recording{container: "ogg"}), do: "audio/ogg"
  def content_type(%Recording{container: "mp4"}), do: "audio/mp4"

  @doc """
  Commits one ordered slice of audio for the given generation.

  Returns the updated recording, or an error naming the exact refusal so the
  browser can stop uploading instead of retrying forever.
  """
  @spec append_chunk(Session.t(), pos_integer(), pos_integer(), binary(), String.t()) ::
          {:ok, Recording.t()} | {:error, term()}
  def append_chunk(%Session{} = session, generation, sequence, data, content_type)
      when is_integer(generation) and is_integer(sequence) and sequence > 0 and is_binary(data) do
    settings = config()

    cond do
      not settings.enabled? ->
        {:error, :voice_recording_disabled}

      byte_size(data) == 0 ->
        {:error, :invalid_recording_chunk}

      byte_size(data) > settings.maximum_chunk_bytes ->
        {:error, :voice_recording_chunk_too_large}

      not Map.has_key?(@content_types, normalize_content_type(content_type)) ->
        {:error, :unsupported_recording_media_type}

      true ->
        result =
          transaction(fn ->
            locked_session = Repo.get_for_update!(Session, session.id)

            with :ok <- require_generation(locked_session, generation),
                 :ok <- require_open_window(locked_session, settings),
                 {:ok, recording} <-
                   open_recording(locked_session, generation, content_type, settings) do
              commit_chunk(recording, sequence, data, settings)
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          # The ceiling is recorded in its own transaction: marking the recording
          # truncated inside the one that refuses the slice would roll the mark
          # back along with the refusal, and the recording would keep claiming to
          # be open forever.
          {:error, {:limit_reached, recording_id}} ->
            _truncated = truncate(recording_id)
            {:error, :voice_recording_limit_reached}

          other ->
            other
        end
    end
  end

  def append_chunk(%Session{}, _generation, _sequence, _data, _content_type),
    do: {:error, :invalid_recording_chunk}

  @doc """
  Closes a recording.

  `"complete"` is the browser reporting a clean stop, `"failed"` is the browser
  reporting that capture itself broke. `client_duration_ms` is the browser's
  own measurement and is stored as a claim, not as a verified duration.
  """
  @spec finalize(Session.t(), pos_integer(), String.t(), non_neg_integer() | nil) ::
          {:ok, Recording.t()} | {:error, term()}
  def finalize(%Session{} = session, generation, status, client_duration_ms)
      when is_integer(generation) and status in ~w(complete failed) do
    transaction(fn ->
      case locked_open_recording(session.id, generation) do
        nil ->
          Repo.rollback(:voice_recording_not_found)

        recording ->
          close(recording, status, client_duration_ms)
      end
    end)
  end

  def finalize(%Session{}, _generation, _status, _duration),
    do: {:error, :invalid_recording_status}

  @doc "The recording for one generation, if any audio was ever uploaded."
  @spec for_session(Session.t()) :: Recording.t() | nil
  def for_session(%Session{id: session_id, generation: generation}) do
    Repo.get_by(Recording, voice_session_id: session_id, generation: generation)
  end

  @spec get(Ecto.UUID.t()) :: Recording.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Recording, uuid)
      :error -> nil
    end
  end

  @doc """
  The recording's audio as one binary.

  Convenient for short recordings and for tests. The operator surface streams
  instead — see `stream/1` — so a long call is never assembled in memory.
  """
  @spec read(Recording.t()) :: {:ok, binary()} | {:error, term()}
  def read(%Recording{} = recording) do
    Repo.transaction(fn -> recording |> stream() |> Enum.join() end)
  end

  @doc """
  The recording's audio as an ordered stream of plaintext slices.

  Only valid as the whole ordered sequence: a slice on its own is not media.
  Must run inside a transaction, because it reads through a database cursor.
  """
  @spec stream(Recording.t()) :: Enumerable.t()
  def stream(%Recording{id: recording_id, sealed: sealed?}) do
    from(chunk in RecordingChunk,
      where: chunk.voice_recording_id == ^recording_id,
      order_by: [asc: chunk.sequence],
      select: {chunk.sequence, chunk.data}
    )
    |> Repo.stream(max_rows: 8)
    |> Stream.map(fn {sequence, data} ->
      if sealed? do
        case RecordingVault.open(data, recording_id, sequence) do
          {:ok, plaintext} -> plaintext
          {:error, reason} -> raise "voice recording chunk could not be opened: #{reason}"
        end
      else
        data
      end
    end)
  end

  @doc """
  Closes recordings left open by a call that ended without finalizing.

  A closed tab, a lost network, or a killed browser all end the call without a
  finalize. The chunks that arrived stay playable; the status stops claiming the
  upload is still in progress.
  """
  @spec abort_stale(DateTime.t()) :: {:ok, non_neg_integer()}
  def abort_stale(now \\ DateTime.utc_now()) do
    settings = config()
    cutoff = DateTime.add(now, -settings.late_chunk_grace_seconds, :second)

    stale =
      Repo.all(
        from(recording in Recording,
          join: session in Session,
          on: session.id == recording.voice_session_id,
          where:
            recording.status == "recording" and session.status in ^@terminal_session_statuses and
              session.ended_at < ^cutoff,
          limit: 500,
          select: recording.id
        )
      )

    aborted =
      Enum.count(stale, fn recording_id ->
        result =
          transaction(fn ->
            case Repo.get_for_update(Recording, recording_id) do
              %Recording{status: "recording"} = recording -> close(recording, "aborted", nil)
              _closed_or_missing -> Repo.rollback(:already_closed)
            end
          end)

        match?({:ok, _recording}, result)
      end)

    {:ok, aborted}
  end

  @doc """
  Deletes audio past its own retention window.

  Audio gets a shorter default life than the lifecycle metadata purged by
  `OpenAgents.Voice.Retention`: a recording is the most sensitive thing Sarah stores,
  so it disappears before the receipts that describe it do.
  """
  @spec purge_expired(DateTime.t()) :: {:ok, non_neg_integer()}
  def purge_expired(now \\ DateTime.utc_now()) do
    settings = config()
    cutoff = DateTime.add(now, -settings.retention_days, :day)

    expired =
      Repo.all(
        from(recording in Recording,
          join: session in Session,
          on: session.id == recording.voice_session_id,
          where: session.status in ^@terminal_session_statuses and session.ended_at < ^cutoff,
          limit: 500,
          select: recording.id
        )
      )

    {count, nil} =
      Repo.delete_all(from(recording in Recording, where: recording.id in ^expired))

    {:ok, count}
  end

  defp commit_chunk(recording, sequence, data, settings) do
    expected = recording.chunk_count + 1

    cond do
      sequence < expected ->
        # A retried upload of a slice already stored. Idempotent by design: the
        # browser cannot know whether a dropped response meant the write failed.
        recording

      sequence > expected ->
        Repo.rollback(:voice_recording_sequence_gap)

      recording.chunk_count >= settings.maximum_chunks ->
        Repo.rollback({:limit_reached, recording.id})

      recording.byte_size + byte_size(data) > settings.maximum_bytes ->
        Repo.rollback({:limit_reached, recording.id})

      true ->
        insert_chunk(recording, sequence, data)

        recording
        |> Recording.append_changeset(%{
          chunk_count: expected,
          byte_size: recording.byte_size + byte_size(data)
        })
        |> update_or_rollback()
    end
  end

  defp insert_chunk(recording, sequence, data) do
    stored =
      if recording.sealed do
        case RecordingVault.seal(data, recording.id, sequence) do
          {:ok, sealed} -> sealed
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        data
      end

    %RecordingChunk{}
    |> RecordingChunk.create_changeset(%{
      voice_recording_id: recording.id,
      sequence: sequence,
      data: stored,
      byte_size: byte_size(data),
      observed_at: DateTime.utc_now()
    })
    |> insert_or_rollback()
  end

  defp truncate(recording_id) do
    transaction(fn ->
      case Repo.get_for_update(Recording, recording_id) do
        %Recording{status: "recording"} = recording -> close(recording, "truncated", nil)
        _closed_or_missing -> Repo.rollback(:already_closed)
      end
    end)
  end

  defp close(recording, status, client_duration_ms) do
    recording
    |> Recording.terminal_changeset(%{
      status: status,
      client_duration_ms: client_duration_ms,
      content_digest: content_digest(recording),
      completed_at: DateTime.utc_now()
    })
    |> update_or_rollback()
  end

  # Digested one slice at a time so a 25 MiB recording never lands in memory
  # whole. Nil for an empty recording: there is nothing to attest to.
  defp content_digest(%Recording{chunk_count: 0}), do: nil

  defp content_digest(%Recording{} = recording) do
    recording
    |> stream()
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp open_recording(session, generation, content_type, settings) do
    case locked_open_recording(session.id, generation) do
      %Recording{} = recording ->
        {:ok, recording}

      nil ->
        if Repo.get_by(Recording, voice_session_id: session.id, generation: generation) do
          {:error, :voice_recording_closed}
        else
          create_recording(session, generation, content_type, settings)
        end
    end
  end

  defp create_recording(session, generation, content_type, settings) do
    {container, codec} = Map.fetch!(@content_types, normalize_content_type(content_type))

    changeset =
      Recording.create_changeset(%Recording{}, %{
        voice_session_id: session.id,
        generation: generation,
        status: "recording",
        container: container,
        codec: codec,
        channel_layout: "mic_left_sarah_right",
        sealed: settings.sealed?,
        started_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, recording} -> {:ok, recording}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp locked_open_recording(session_id, generation) do
    Repo.get_by_for_update(Recording,
      voice_session_id: session_id,
      generation: generation,
      status: "recording"
    )
  end

  defp require_generation(%Session{generation: generation}, generation), do: :ok
  defp require_generation(%Session{}, _generation), do: {:error, :stale_voice_generation}

  # The last slice legitimately arrives after the call ends: the browser stops
  # the recorder as part of ending. A bounded grace window admits that tail
  # without leaving an upload endpoint open on a long-dead session.
  defp require_open_window(%Session{status: status}, _settings)
       when status not in @terminal_session_statuses,
       do: :ok

  defp require_open_window(%Session{ended_at: nil}, _settings), do: :ok

  defp require_open_window(%Session{ended_at: ended_at}, settings) do
    if DateTime.diff(DateTime.utc_now(), ended_at, :second) <= settings.late_chunk_grace_seconds,
      do: :ok,
      else: {:error, :voice_recording_window_closed}
  end

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.replace(" ", "")
  end

  defp normalize_content_type(_content_type), do: ""

  defp transaction(function) do
    case Repo.transaction(function) do
      {:ok, %Recording{} = recording} -> {:ok, recording}
      {:ok, other} -> {:ok, other}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
