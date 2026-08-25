defmodule OpenAgents.Forge.AtRestTest do
  @moduledoc """
  EXIT-006, VAULT-001, issue #193.

  `encrypted_at_rest` was a literal `false` on the status page. A literal
  cannot fail, so it said nothing about the store — not even the part that was
  true, which is that three columns do rest as ciphertext.

  These are the assertions that make the boolean mean something. Two of them
  read raw columns back through SQL rather than through Ecto, because a schema
  that loads a value through a type is exactly the layer that would hide the
  answer: the question is what PostgreSQL holds, so PostgreSQL is asked.

  The third is the one worth keeping. The population of secret-shaped columns
  comes from `information_schema`, so a migration that adds a plaintext token
  column fails here on the day it lands. A test of the columns someone thought
  of cannot fail on the column they did not.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.AtRest
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.TranscriptItem

  describe "the sealed columns rest as ciphertext" do
    test "a GitHub access token is not readable in its own column" do
      {:ok, user} = Accounts.upsert_github_user(github_profile("at-rest-github"))
      token = "gho_at_rest_#{System.unique_integer([:positive])}"

      assert {:ok, connected} = Accounts.store_github_token(user, token)

      # The application still reads it, so the seal is a seal and not a loss.
      assert {:ok, ^token} = Accounts.github_token(connected)

      stored = raw_column("users", "github_token_ciphertext", connected.id)

      assert is_binary(stored) and byte_size(stored) > 0,
             "the fixture must actually store something"

      refute contains?(stored, token),
             "users.github_token_ciphertext holds the token PostgreSQL was supposed to hide"
    end

    test "a pairing token is not readable in its own column" do
      {:ok, %{pairing: pairing, code: code, poll_secret: poll_secret}} =
        Machines.start_pairing(%{"name" => "box", "tier" => "probe"})

      {:ok, _machine} = Machines.approve_pairing(github_user("at-rest-pairing"), code)

      stored = raw_column("machine_pairings", "token_ciphertext", pairing.id)

      assert is_binary(stored) and byte_size(stored) > 0,
             "the fixture must actually hold a sealed token"

      # The claim returns the plaintext exactly once, which is the only reader.
      assert {:ok, %{token: token}} = Machines.claim_pairing(pairing.id, poll_secret)

      refute contains?(stored, token),
             "machine_pairings.token_ciphertext holds the token it was supposed to seal"
    end

    test "a call audio slice is not readable in its own column" do
      audio = "opus-bytes-#{System.unique_integer([:positive])}"
      session = admitted_voice_session("at-rest-audio")

      assert {:ok, recording} =
               Voice.Recordings.append_chunk(
                 session,
                 session.generation,
                 1,
                 audio,
                 "audio/webm;codecs=opus"
               )

      assert recording.sealed
      assert {:ok, ^audio} = Voice.Recordings.read(recording)

      %{rows: [[stored]]} =
        Repo.query!(
          "SELECT data FROM voice_recording_chunks WHERE voice_recording_id = $1 AND sequence = 1",
          [Ecto.UUID.dump!(recording.id)]
        )

      refute contains?(stored, audio),
             "voice_recording_chunks.data holds the audio VOICE-012 says is sealed"
    end
  end

  describe "the plaintext columns rest as plaintext" do
    # A ledger that names a gap has to be capable of being wrong about it.
    # These read the same way the sealed assertions do and expect the opposite
    # answer, so a column that quietly became sealed stops being published as
    # a gap in the same commit.
    test "every column plaintext_private_columns/0 names is plaintext in PostgreSQL" do
      for column <- AtRest.plaintext_private_columns() do
        {id, written} = write_private_row(column)
        stored = raw_column(column.table, column.column, id)

        assert contains?(stored, written),
               "#{column.table}.#{column.column} is named as plaintext but PostgreSQL " <>
                 "does not hold the plaintext. If it is sealed now, take it off the list."
      end
    end
  end

  describe "the population comes from the database" do
    test "every secret-shaped column the catalog reports is classified" do
      unclassified =
        for {table, column} <- secret_shaped_columns(),
            is_nil(AtRest.classification(table, column)),
            do: "#{table}.#{column}"

      assert unclassified == [],
             "These columns carry secret-shaped names and OpenAgents.Forge.AtRest does " <>
               "not say where their contents rest:\n  " <>
               Enum.join(unclassified, "\n  ") <>
               "\n\nClassify each one. If any holds reversible secret material in " <>
               "plaintext, seal it under a vault rather than classifying it away."
    end

    test "no column is classified as a plaintext secret" do
      # The security assertion. Everything else in this file exists to make
      # this one capable of failing.
      plaintext_secrets =
        for {{table, column}, :plaintext_secret} <- AtRest.classifications(),
            do: "#{table}.#{column}"

      assert plaintext_secrets == [],
             "Reversible secret material rests as plaintext in: " <>
               Enum.join(plaintext_secrets, ", ")
    end

    test "the ledger classifies nothing the catalog does not have" do
      catalog = MapSet.new(secret_shaped_columns())

      stale =
        for {{table, column}, _classification} <- AtRest.classifications(),
            not MapSet.member?(catalog, {table, column}),
            do: "#{table}.#{column}"

      assert stale == [],
             "OpenAgents.Forge.AtRest classifies columns PostgreSQL does not have: " <>
               Enum.join(stale, ", ")
    end

    test "every sealed column exists and names a vault that can seal and open" do
      for sealed <- AtRest.sealed_columns() do
        assert column_exists?(sealed.table, sealed.column),
               "#{sealed.table}.#{sealed.column} is named as sealed but does not exist"

        assert Code.ensure_loaded?(sealed.vault),
               "#{inspect(sealed.vault)} does not exist"

        assert function_exported?(sealed.vault, :seal, 1) or
                 function_exported?(sealed.vault, :seal, 3),
               "#{inspect(sealed.vault)} exports no seal/1 or seal/3"

        assert function_exported?(sealed.vault, :open, 1) or
                 function_exported?(sealed.vault, :open, 3),
               "#{inspect(sealed.vault)} exports no open/1 or open/3"
      end
    end
  end

  describe "the disclosure derives from this ledger" do
    test "encrypted_at_rest? is exactly whether the plaintext list is empty" do
      assert AtRest.encrypted_at_rest?() == Enum.empty?(AtRest.plaintext_private_columns())
    end

    test "the store is not encrypted at rest today, and the ledger says why" do
      refute AtRest.encrypted_at_rest?()
      assert length(AtRest.plaintext_private_columns()) > 0
    end

    test "the status projection publishes this value rather than a literal" do
      # EXIT-006 derives `encrypted_at_rest` from this module. If the
      # projection stops asking, this fails even though the published boolean
      # does not change, which is the mutation the old literal could not catch.
      section = OpenAgents.Forge.Independence.projection()["private_data"]

      assert section["encrypted_at_rest"] == AtRest.encrypted_at_rest?()
      assert section["operator_reads_source"] == not AtRest.encrypted_at_rest?()
    end

    test "the disclosure is compiled against this module, not against a literal" do
      # Comparing the two values cannot catch a revert to `false`, because
      # `false` is the answer today. The compiled import table can: the
      # projection either reaches this module or it does not. Same read
      # EXIT-006 already uses for `export_recipient_encryption`.
      assert AtRest in external_calls(OpenAgents.Forge.Independence),
             "EXIT-006 derives `encrypted_at_rest` from OpenAgents.Forge.AtRest. " <>
               "OpenAgents.Forge.Independence no longer calls it, so the published " <>
               "boolean is a literal again even though its value has not changed."
    end
  end

  defp external_calls(module) do
    case :beam_lib.chunks(:code.which(module), [:imports]) do
      {:ok, {^module, [imports: imports]}} -> Enum.map(imports, &elem(&1, 0))
      _unreadable -> []
    end
  end

  # ── reading PostgreSQL rather than Ecto ──────────────────────────────────

  defp raw_column(table, column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump_id(id)])

    value
  end

  # Primary keys here are UUIDs or integers depending on the table.
  defp dump_id(id) when is_integer(id), do: id
  defp dump_id(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  defp contains?(nil, _needle), do: false

  defp contains?(haystack, needle) when is_binary(haystack) and is_binary(needle),
    do: :binary.match(haystack, needle) != :nomatch

  defp column_exists?(table, column) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    count == 1
  end

  defp secret_shaped_columns do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND t.table_type = 'BASE TABLE'
          AND (c.column_name ~ $1 OR c.column_name LIKE '%\\_key')
        """,
        [AtRest.secret_shaped_pattern()]
      )

    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  # ── writing one real row per named plaintext column ──────────────────────

  defp write_private_row(%{table: "messages", column: "content"}) do
    content = "plaintext-message-#{System.unique_integer([:positive])}"
    {:ok, conversation} = Conversations.ensure_conversation("at-rest-message")
    {:ok, message} = Conversations.create_voice_context_message(conversation, content)

    {message.id, content}
  end

  defp write_private_row(%{table: "voice_transcript_items", column: "content"}) do
    # Voice creates these inside the sideband handler, so the insert goes
    # through the schema's own changeset here. That is the layer under test:
    # "no Ecto column is encrypted at rest" is a claim about the types a
    # schema declares, and this is the type layer answering.
    content = "plaintext-transcript-#{System.unique_integer([:positive])}"
    session = admitted_voice_session("at-rest-transcript")

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

    {item.id, content}
  end

  defp write_private_row(%{table: "issues", column: "body"}) do
    body = "plaintext-issue-#{System.unique_integer([:positive])}"
    repository = OpenAgents.AccountsFixtures.repository_fixture()

    {:ok, issue} =
      OpenAgents.Issues.create_issue(repository, %{title: "at rest", body: body})

    {issue.id, body}
  end

  defp write_private_row(%{table: "comments", column: "body"}) do
    body = "plaintext-comment-#{System.unique_integer([:positive])}"
    user = github_user("at-rest-comment")
    repository = OpenAgents.AccountsFixtures.repository_fixture()
    {:ok, issue} = OpenAgents.Issues.create_issue(repository, %{title: "at rest"})
    {:ok, comment} = OpenAgents.Issues.create_comment(issue, %{"body" => body}, user)

    {comment.id, body}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp github_profile(key) do
    digest = :crypto.hash(:sha256, key)

    %{
      github_id: digest |> binary_part(0, 7) |> :binary.decode_unsigned(),
      github_login: "at-rest-#{Base.encode16(digest, case: :lower) |> binary_part(0, 10)}",
      github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
    }
  end

  defp github_user(key) do
    {:ok, user} = Accounts.upsert_github_user(github_profile(key))
    user
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
