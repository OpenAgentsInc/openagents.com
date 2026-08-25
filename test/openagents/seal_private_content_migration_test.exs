defmodule OpenAgents.SealPrivateContentMigrationTest do
  use OpenAgents.DataCase

  @moduledoc """
  Proves the issue #193 backfill migration actually seals existing plaintext
  rows and that the application reads them back identically through the
  schemas.

  A unit test of the vault proves the crypto works. This test proves the
  *binding* works: that the migration and the application schema bind each
  table under the exact same identity strings, so a row sealed by the
  migration is readable by the schema, not dropped or rejected as corrupt.
  """

  # Require the migration file to define the module during testing
  Code.require_file("priv/repo/migrations/20260825170100_seal_private_content.exs")

  alias OpenAgents.Accounts
  alias OpenAgents.Conversations
  alias OpenAgents.Preferences
  alias OpenAgents.Preferences.Observation
  alias OpenAgents.Projects
  alias OpenAgents.Projects.ProjectNote
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Repo.Migrations.SealPrivateContent
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Session
  alias OpenAgents.Voice.TranscriptItem

  test "every sealed column survives the backfill and reads back through the application" do
    t_row = transcript_row()
    c_row = compaction_row()
    o_row = observation_row()
    n_row = note_row()
    rows = [t_row, c_row, o_row, n_row]

    Enum.each(rows, &unseal_in_place!/1)

    # Every row now rests the way the migration will find it on a database that
    # has never run the backfill.
    for %{table: table, plaintext: plaintext, ciphertext: ciphertext, id: id} <- rows do
      assert raw(table, plaintext, id)
      refute raw(table, ciphertext, id)
    end

    SealPrivateContent.run_direct!(Repo, :seal)

    for %{table: table, plaintext: plaintext, ciphertext: ciphertext, id: id, written: written} <-
          rows do
      refute raw(table, plaintext, id),
             "#{table}.#{plaintext} still holds plaintext after the backfill"

      sealed = raw(table, ciphertext, id)
      assert is_binary(sealed) and byte_size(sealed) > 0
      refute :binary.match(sealed, written) != :nomatch
    end

    for %{name: name, read: read, written: written} <- rows do
      assert read.() == written,
             "#{name}: the backfill sealed this row under an identity the schema does not " <>
               "reconstruct, so the application reads nothing back (got #{inspect(read.())})"
    end
  end

  # Rewrites one sealed row back into the plaintext column, which is the state
  # every row is in before this migration runs.
  defp unseal_in_place!(
         %{table: table, plaintext: plaintext, ciphertext: ciphertext, id: id} = row
       ) do
    if table == "preference_observations" do
      Repo.query!(
        "ALTER TABLE preference_observations DISABLE TRIGGER preference_observations_append_only"
      )
    end

    try do
      Repo.query!(
        "UPDATE #{table} SET #{plaintext} = $1, #{ciphertext} = NULL WHERE id = $2",
        [row.written, dump_id(id)]
      )
    after
      if table == "preference_observations" do
        Repo.query!(
          "ALTER TABLE preference_observations ENABLE TRIGGER preference_observations_append_only"
        )
      end
    end

    row
  end

  defp transcript_row do
    content = "backfill-transcript-#{System.unique_integer([:positive])}"
    session = admitted_voice_session("backfill-transcript")

    {:ok, item} =
      %TranscriptItem{}
      |> TranscriptItem.create_changeset(%{
        voice_session_id: session.id,
        generation: session.generation,
        provider_item_id: "item-#{System.unique_integer([:positive])}",
        role: "user",
        content: content,
        status: "final",
        observed_at: DateTime.utc_now()
      })
      |> Repo.insert()

    %{
      name: "voice_transcript_item",
      table: "voice_transcript_items",
      plaintext: "content",
      ciphertext: "content_ciphertext",
      id: item.id,
      written: content,
      read: fn -> TranscriptItem.text(Repo.get!(TranscriptItem, item.id)) end
    }
  end

  defp compaction_row do
    summary = "backfill-compaction-#{System.unique_integer([:positive])}"
    session = admitted_voice_session("backfill-compaction")

    {:ok, updated, _} =
      Voice.record_compaction_summary(session, session.generation, summary)

    %{
      name: "voice_session_compaction",
      table: "voice_sessions",
      plaintext: "compaction_summary",
      ciphertext: "compaction_summary_ciphertext",
      id: updated.id,
      written: summary,
      read: fn -> Session.compaction_summary(Repo.get!(Session, updated.id)) end
    }
  end

  defp observation_row do
    summary = "backfill-pref-#{System.unique_integer([:positive])}"
    {owner, conversation} = owner_conversation("backfill-observation")
    {:ok, source} = Conversations.create_voice_context_message(conversation, "source")

    {:ok, observation} =
      Preferences.observe(owner, %{
        "source_kind" => "current_user_message",
        "source_message_id" => source.id,
        "summary" => summary,
        "confidence_millis" => 900,
        "proposer_id" => "openagents.backfill.test",
        "proposer_digest" => Canonical.sha256("openagents.backfill.test")
      })

    %{
      name: "preference_observation",
      table: "preference_observations",
      plaintext: "summary",
      ciphertext: "summary_ciphertext",
      id: observation.id,
      written: summary,
      read: fn -> Observation.summary(Repo.get!(Observation, observation.id)) end
    }
  end

  defp note_row do
    body = "backfill-note-#{System.unique_integer([:positive])}"
    repository = OpenAgents.AccountsFixtures.repository_fixture()
    author = github_user("backfill-note")

    {:ok, project} =
      Projects.create_project(repository, %{title: "Backfill Note", owner: author.github_login})

    {:ok, note} = Projects.create_project_note(project, %{"body" => body}, author)

    %{
      name: "project_note",
      table: "project_notes",
      plaintext: "body",
      ciphertext: "body_ciphertext",
      id: note.id,
      written: body,
      read: fn -> ProjectNote.text(Repo.get!(ProjectNote, note.id)) end
    }
  end

  defp raw(table, column, id) do
    %{rows: [[val]]} =
      Repo.query!(
        "SELECT #{column} FROM #{table} WHERE id = $1",
        [dump_id(id)]
      )

    val
  end

  defp dump_id(id) when is_integer(id), do: id
  defp dump_id(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  defp github_profile(key) do
    digest = :crypto.hash(:sha256, key)

    %{
      github_id: digest |> binary_part(0, 7) |> :binary.decode_unsigned(),
      github_login: "backfill-#{Base.encode16(digest, case: :lower) |> binary_part(0, 10)}",
      github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
    }
  end

  defp github_user(key) do
    {:ok, user} = Accounts.upsert_github_user(github_profile(key))
    user
  end

  defp owner_conversation(key) do
    {:ok, conversation} = Conversations.ensure_conversation(key)
    {Conversations.get_conversation_owner!(conversation), conversation}
  end

  defp admitted_voice_session(key) do
    {:ok, conversation} = Conversations.ensure_conversation(key)
    {:ok, session} = Voice.admit_session(conversation, voice_config())
    session
  end

  defp voice_config do
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
