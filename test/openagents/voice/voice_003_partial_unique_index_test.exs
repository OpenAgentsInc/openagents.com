defmodule OpenAgents.Voice.Voice003PartialUniqueIndexTest do
  @moduledoc """
  VOICE-003, at the database. The partial unique index allows only one active
  voice session per conversation. These claims bypass the Ecto changeset and
  write raw SQL, because the property is that PostgreSQL refuses the row.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  @initial_control_id "00000000-0000-0000-0000-000000000001"

  @insert """
  INSERT INTO voice_sessions
    (id, conversation_id, generation, status, architecture, provider_id,
     model_id, voice_artifact_id, provider_session_id, persona_id,
     persona_digest, role_id, role_digest, instruction_digest,
     tool_catalog_digest, event_sequence, usage, started_at, connected_at,
     ended_at, termination_reason, failure_code, release_control_id,
     inserted_at, updated_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
     $11, $12, $13, $14, $15, $16, $17, $18, $19, $20,
     $21, $22, $23, $24, $25)
  """

  setup do
    {:ok, conversation} =
      Conversations.ensure_conversation("voice-003-browser")

    %{conversation: conversation}
  end

  describe "one active session per conversation" do
    test "a second active session is refused by the partial unique index",
         %{conversation: conversation} do
      conversation_id = uuid(conversation.id)
      now = DateTime.utc_now()

      first_id = uuid(Ecto.UUID.generate())

      assert {:ok, %{num_rows: 1}} =
               insert_voice_session(
                 first_id,
                 conversation_id,
                 1,
                 "connecting",
                 now
               )

      second_id = uuid(Ecto.UUID.generate())

      assert {:error, %Postgrex.Error{} = error} =
               insert_voice_session(
                 second_id,
                 conversation_id,
                 2,
                 "listening",
                 now
               )

      assert error.postgres.constraint ==
               "voice_sessions_one_active_per_conversation_index"
    end

    test "a terminal session for the same conversation is admitted",
         %{conversation: conversation} do
      conversation_id = uuid(conversation.id)
      now = DateTime.utc_now()

      assert {:ok, %{num_rows: 1}} =
               insert_voice_session(
                 uuid(Ecto.UUID.generate()),
                 conversation_id,
                 1,
                 "connecting",
                 now
               )

      assert {:ok, %{num_rows: 1}} =
               insert_voice_session(
                 uuid(Ecto.UUID.generate()),
                 conversation_id,
                 2,
                 "ended",
                 now,
                 now,
                 "test"
               )
    end
  end

  defp insert_voice_session(
         id,
         conversation_id,
         generation,
         status,
         started_at,
         ended_at \\ nil,
         termination_reason \\ nil
       ) do
    Repo.query(@insert, [
      id,
      conversation_id,
      generation,
      status,
      "openai.realtime",
      "openai",
      "openai.gpt-realtime-2.1.2026-08-16",
      "sarah.voice.openai.marin.v1",
      nil,
      "sarah.persona.voice.v1",
      String.duplicate("0", 64),
      "sarah.role.voice.v1",
      String.duplicate("1", 64),
      String.duplicate("2", 64),
      String.duplicate("3", 64),
      0,
      %{},
      started_at,
      nil,
      ended_at,
      termination_reason,
      nil,
      uuid(@initial_control_id),
      started_at,
      started_at
    ])
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
