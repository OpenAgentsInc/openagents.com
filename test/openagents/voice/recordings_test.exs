defmodule OpenAgents.Voice.RecordingsTest do
  @moduledoc """
  Call audio is the first raw media Sarah stores, and it arrives from an
  untrusted client on an endpoint that accepts bytes. These tests cover the four
  things that keeps honest: ordering, fencing, ceilings, and sealing.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Repo
  alias OpenAgents.Voice
  alias OpenAgents.Voice.{Config, Recording, RecordingChunk, RecordingVault, Recordings}

  @webm "audio/webm;codecs=opus"

  describe "append_chunk/5" do
    test "commits slices in order, sealed, and idempotently on a retry" do
      session = admitted_session("recording-order")

      assert {:ok, first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      assert first.status == "recording"
      assert first.container == "webm"
      assert first.codec == "opus"
      assert first.channel_layout == "mic_left_sarah_right"
      assert first.sealed
      assert first.chunk_count == 1
      assert first.byte_size == 3

      assert {:ok, second} =
               Recordings.append_chunk(session, session.generation, 2, "bbbb", @webm)

      assert second.chunk_count == 2
      assert second.byte_size == 7

      # A dropped response leaves the browser unable to know whether the write
      # landed, so a repeat of a stored sequence is a no-op rather than a
      # duplicate slice or a refusal.
      assert {:ok, retried} =
               Recordings.append_chunk(session, session.generation, 2, "bbbb", @webm)

      assert retried.chunk_count == 2
      assert retried.byte_size == 7

      # Ciphertext at rest, and the plaintext only through the sanctioned reader.
      stored = Repo.all(from(chunk in RecordingChunk, order_by: chunk.sequence))
      assert Enum.map(stored, & &1.sequence) == [1, 2]
      refute Enum.any?(stored, &(&1.data in ["aaa", "bbbb"]))

      assert {:ok, "aaabbbb"} = Recordings.read(retried)
    end

    test "refuses a gap, because a missing slice makes the rest unplayable" do
      session = admitted_session("recording-gap")

      assert {:error, :voice_recording_sequence_gap} =
               Recordings.append_chunk(session, session.generation, 2, "aaa", @webm)

      assert {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)

      assert {:error, :voice_recording_sequence_gap} =
               Recordings.append_chunk(session, session.generation, 4, "bbb", @webm)
    end

    test "refuses a stale generation the way every other voice write does" do
      session = admitted_session("recording-generation")

      assert {:error, :stale_voice_generation} =
               Recordings.append_chunk(session, session.generation + 1, 1, "aaa", @webm)

      assert Repo.aggregate(Recording, :count) == 0
    end

    test "truncates at the chunk ceiling instead of growing without limit" do
      session = admitted_session("recording-chunk-ceiling")
      maximum = Recordings.config().maximum_chunks

      for sequence <- 1..maximum do
        assert {:ok, _recording} =
                 Recordings.append_chunk(session, session.generation, sequence, "aa", @webm)
      end

      assert {:error, :voice_recording_limit_reached} =
               Recordings.append_chunk(session, session.generation, maximum + 1, "aa", @webm)

      recording = Recordings.for_session(session)
      assert recording.status == "truncated"
      assert recording.chunk_count == maximum
      assert recording.completed_at

      # Truncated audio is still audio: the operator gets what arrived.
      assert recording.status in Recording.playable_statuses()
    end

    test "truncates at the byte ceiling and refuses an oversized single slice" do
      session = admitted_session("recording-byte-ceiling")
      settings = Recordings.config()

      assert {:error, :voice_recording_chunk_too_large} =
               Recordings.append_chunk(
                 session,
                 session.generation,
                 1,
                 :binary.copy("a", settings.maximum_chunk_bytes + 1),
                 @webm
               )

      slice = :binary.copy("a", settings.maximum_chunk_bytes)
      slices = div(settings.maximum_bytes, settings.maximum_chunk_bytes)

      for sequence <- 1..slices do
        assert {:ok, _recording} =
                 Recordings.append_chunk(session, session.generation, sequence, slice, @webm)
      end

      assert {:error, :voice_recording_limit_reached} =
               Recordings.append_chunk(session, session.generation, slices + 1, slice, @webm)

      assert Recordings.for_session(session).status == "truncated"
    end

    test "refuses a media type outside the stored container allowlist" do
      session = admitted_session("recording-media-type")

      assert {:error, :unsupported_recording_media_type} =
               Recordings.append_chunk(session, session.generation, 1, "aaa", "audio/wav")

      assert {:error, :unsupported_recording_media_type} =
               Recordings.append_chunk(session, session.generation, 1, "aaa", "text/html")
    end

    test "accepts the tail slice after the call ends, then closes the window" do
      session = admitted_session("recording-late-slice")
      {:ok, session} = Voice.end_session(session, session.generation, "user_ended")

      # Ending the call is what stops the recorder, so its last slice is always
      # late by definition.
      assert {:ok, recording} =
               Recordings.append_chunk(session, session.generation, 1, "tail", @webm)

      assert recording.chunk_count == 1

      grace = Recordings.config().late_chunk_grace_seconds

      stale =
        session
        |> Ecto.Changeset.change(%{
          ended_at: DateTime.add(DateTime.utc_now(), -grace - 5, :second)
        })
        |> Repo.update!()

      assert {:error, :voice_recording_window_closed} =
               Recordings.append_chunk(stale, stale.generation, 2, "later", @webm)
    end

    test "refuses to reopen a closed recording" do
      session = admitted_session("recording-reopen")
      assert {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      assert {:ok, _closed} = Recordings.finalize(session, session.generation, "complete", 1_000)

      assert {:error, :voice_recording_closed} =
               Recordings.append_chunk(session, session.generation, 2, "bbb", @webm)
    end

    test "records nothing when no key is configured, rather than storing audio in the clear" do
      session = admitted_session("recording-unsealed")

      without_recording_key(fn ->
        refute Recordings.config().enabled?

        assert {:error, :voice_recording_disabled} =
                 Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      end)

      assert Repo.aggregate(Recording, :count) == 0
    end
  end

  describe "finalize/4" do
    test "closes with the browser's duration claim and a digest over the audio" do
      session = admitted_session("recording-finalize")
      {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      {:ok, _second} = Recordings.append_chunk(session, session.generation, 2, "bbb", @webm)

      assert {:ok, recording} =
               Recordings.finalize(session, session.generation, "complete", 7_500)

      assert recording.status == "complete"
      assert recording.client_duration_ms == 7_500
      assert recording.completed_at

      assert recording.content_digest ==
               :crypto.hash(:sha256, "aaabbb") |> Base.encode16(case: :lower)
    end

    test "a browser reporting failed capture closes the recording as failed" do
      session = admitted_session("recording-failed")
      {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)

      assert {:ok, recording} = Recordings.finalize(session, session.generation, "failed", nil)
      assert recording.status == "failed"
      refute recording.status in Recording.playable_statuses()
    end

    test "finalizing a call that uploaded nothing is not an error" do
      session = admitted_session("recording-nothing")

      assert {:error, :voice_recording_not_found} =
               Recordings.finalize(session, session.generation, "complete", 0)
    end
  end

  describe "lifecycle sweeps" do
    test "abort_stale/1 closes a recording the browser never finalized" do
      session = admitted_session("recording-abandoned")
      {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      {:ok, session} = Voice.end_session(session, session.generation, "client_disconnected")

      # Inside the grace window the upload may still be in flight.
      assert {:ok, 0} = Recordings.abort_stale()
      assert Recordings.for_session(session).status == "recording"

      grace = Recordings.config().late_chunk_grace_seconds

      session
      |> Ecto.Changeset.change(%{
        ended_at: DateTime.add(DateTime.utc_now(), -grace - 5, :second)
      })
      |> Repo.update!()

      assert {:ok, 1} = Recordings.abort_stale()

      aborted = Recordings.for_session(session)
      assert aborted.status == "aborted"
      # What arrived is still playable; the status stops claiming an upload is
      # still running.
      assert aborted.status in Recording.playable_statuses()
      assert {:ok, "aaa"} = Recordings.read(aborted)
    end

    test "purge_expired/1 deletes audio on its own shorter window" do
      session = admitted_session("recording-retention")
      {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      {:ok, session} = Voice.end_session(session, session.generation, "user_ended")

      assert {:ok, 0} = Recordings.purge_expired()

      retention_days = Recordings.config().retention_days

      session
      |> Ecto.Changeset.change(%{
        ended_at: DateTime.add(DateTime.utc_now(), -retention_days - 1, :day)
      })
      |> Repo.update!()

      assert {:ok, 1} = Recordings.purge_expired()
      refute Recordings.for_session(session)
      assert Repo.aggregate(RecordingChunk, :count) == 0

      # The call itself survives its audio: lifecycle evidence has a longer life.
      assert Voice.get_session!(session.id)
    end

    test "deleting the account's data removes its audio by cascade" do
      user = github_user("recording-cascade")
      {:ok, conversation} = Conversations.ensure_conversation(user)
      {:ok, session} = Voice.admit_session(conversation, enabled_config())
      {:ok, _first} = Recordings.append_chunk(session, session.generation, 1, "aaa", @webm)
      {:ok, _ended} = Voice.end_session(session, session.generation, "user_ended")

      owner = Conversations.get_conversation_owner!(conversation)

      assert {:ok, :deleted} =
               OpenAgents.DataRights.delete(
                 user,
                 owner,
                 Conversations.get_conversation_for_user(user)
               )

      assert Repo.aggregate(Recording, :count) == 0
      assert Repo.aggregate(RecordingChunk, :count) == 0
    end
  end

  describe "sealing" do
    test "a chunk cannot be opened under another recording or another sequence" do
      assert {:ok, sealed} = RecordingVault.seal("audio", Ecto.UUID.generate(), 1)

      recording_id = Ecto.UUID.generate()
      assert {:ok, bound} = RecordingVault.seal("audio", recording_id, 4)
      assert {:ok, "audio"} = RecordingVault.open(bound, recording_id, 4)

      # Moving a slice to another recording, or to another position in the same
      # one, fails to open rather than silently reordering the audio.
      assert {:error, :chunk_unsealable} =
               RecordingVault.open(bound, Ecto.UUID.generate(), 4)

      assert {:error, :chunk_unsealable} = RecordingVault.open(bound, recording_id, 5)
      assert {:error, :chunk_unsealable} = RecordingVault.open(sealed, recording_id, 4)
    end

    test "legacy Sarah version-1 chunks remain readable during migration" do
      recording_id = Ecto.UUID.generate()
      sequence = 3
      nonce = :crypto.strong_rand_bytes(12)

      {:ok, key} =
        Base.decode64(Application.fetch_env!(:openagents, :voice_recording_encryption_key))

      aad = "sarah.voice_recording_chunk.v1:#{recording_id}:#{sequence}"

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, "legacy audio", aad, true)

      sealed = <<1, nonce::binary, tag::binary, ciphertext::binary>>
      assert {:ok, "legacy audio"} = RecordingVault.open(sealed, recording_id, sequence)
    end

    test "a wrong key fails closed" do
      recording_id = Ecto.UUID.generate()
      assert {:ok, sealed} = RecordingVault.seal("audio", recording_id, 1)

      original = Application.get_env(:openagents, :voice_recording_encryption_key)

      try do
        Application.put_env(
          :openagents,
          :voice_recording_encryption_key,
          Base.encode64(String.duplicate("x", 32))
        )

        assert {:error, :chunk_unsealable} = RecordingVault.open(sealed, recording_id, 1)
      after
        Application.put_env(:openagents, :voice_recording_encryption_key, original)
      end
    end
  end

  defp admitted_session(key) do
    {:ok, conversation} = Conversations.ensure_conversation(key)
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    session
  end

  defp github_user(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{Base.encode16(digest, case: :lower) |> binary_part(0, 10)}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp without_recording_key(function) do
    original = Application.get_env(:openagents, :voice_recording_encryption_key)

    try do
      Application.put_env(:openagents, :voice_recording_encryption_key, nil)
      function.()
    after
      Application.put_env(:openagents, :voice_recording_encryption_key, original)
    end
  end

  defp enabled_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end
end
