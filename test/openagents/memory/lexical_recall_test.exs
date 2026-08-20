defmodule OpenAgents.Memory.LexicalRecallTest do
  use OpenAgents.DataCase

  alias OpenAgents.{Context.Composer, Conversations, Repo}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Memory.LexicalRecall
  alias OpenAgents.Providers.Request

  test "finds a bounded unusual identifier older than the provider window after snapshot reload" do
    {:ok, conversation} = Conversations.ensure_conversation("lexical-old-message-browser")
    base = DateTime.utc_now() |> DateTime.add(-3_600, :second)

    target =
      insert_message(
        conversation.id,
        "user",
        "The deployment identifier is project_slug_9f8a2 and should remain searchable.",
        base
      )

    for index <- 1..40 do
      insert_message(
        conversation.id,
        if(rem(index, 2) == 0, do: "user", else: "assistant"),
        "ordinary filler message #{index}",
        DateTime.add(base, index, :second)
      )
    end

    refute Enum.any?(Conversations.provider_messages(conversation.id), fn message ->
             String.contains?(message.content, "project_slug_9f8a2")
           end)

    receipt = begin_inference(conversation, "Find the deployment identifier.")

    assert {:ok, snapshot} =
             LexicalRecall.load_snapshot(conversation, receipt.memory_snapshot_ref)

    assert {:ok, [match]} = LexicalRecall.search(conversation, snapshot, "project_slug_9f8a2")

    assert match.source_ref == "message:#{target.id}"
    assert match.role == "user"
    assert match.rank == 1
    assert byte_size(match.excerpt) <= 800
    refute match.truncated

    assert {:ok, reloaded_snapshot} =
             LexicalRecall.load_snapshot(conversation, receipt.memory_snapshot_ref)

    assert {:ok, reloaded_matches} =
             LexicalRecall.search(conversation, reloaded_snapshot, "project_slug_9f8a2")

    assert Enum.map(reloaded_matches, & &1.source_ref) == ["message:#{target.id}"]
  end

  test "scope is enforced by both snapshot lookup and every search" do
    {:ok, first} = Conversations.ensure_conversation("lexical-first-browser")
    {:ok, second} = Conversations.ensure_conversation("lexical-second-browser")
    insert_message(first.id, "user", "private nebula phrase", DateTime.utc_now())

    receipt = begin_inference(first, "Recall the nebula phrase.")
    assert {:ok, snapshot} = LexicalRecall.load_snapshot(first, receipt.memory_snapshot_ref)

    assert {:error, :scope_refused} =
             LexicalRecall.load_snapshot(second, receipt.memory_snapshot_ref)

    assert {:error, :scope_refused} = LexicalRecall.search(second, snapshot, "nebula")
  end

  test "failed and streaming assistant text never enters recall" do
    {:ok, conversation} = Conversations.ensure_conversation("lexical-status-browser")
    base = DateTime.utc_now()
    insert_message(conversation.id, "user", "eligible anchor", base)
    insert_message(conversation.id, "assistant", "failed_secret_token", base, "failed")
    insert_message(conversation.id, "assistant", "streaming_secret_token", base, "streaming")

    receipt = begin_inference(conversation, "Search prior text.")

    assert {:ok, snapshot} =
             LexicalRecall.load_snapshot(conversation, receipt.memory_snapshot_ref)

    assert {:ok, []} = LexicalRecall.search(conversation, snapshot, "failed_secret_token")
    assert {:ok, []} = LexicalRecall.search(conversation, snapshot, "streaming_secret_token")
  end

  test "the high-water cursor excludes later matches and ordering is deterministic" do
    {:ok, conversation} = Conversations.ensure_conversation("lexical-snapshot-browser")
    timestamp = DateTime.utc_now() |> DateTime.add(-60, :second)
    first = insert_message(conversation.id, "user", "stable comet marker", timestamp)
    second = insert_message(conversation.id, "assistant", "stable comet marker", timestamp)

    receipt = begin_inference(conversation, "What was the comet marker?")

    assert {:ok, snapshot} =
             LexicalRecall.load_snapshot(conversation, receipt.memory_snapshot_ref)

    later =
      insert_message(
        conversation.id,
        "user",
        "later stable comet marker",
        DateTime.add(snapshot.inserted_at, 1, :second)
      )

    assert {:ok, first_read} = LexicalRecall.search(conversation, snapshot, "stable comet marker")

    assert {:ok, second_read} =
             LexicalRecall.search(conversation, snapshot, "stable comet marker")

    first_refs = Enum.map(first_read, & &1.source_ref)
    assert first_refs == Enum.map(second_read, & &1.source_ref)
    assert "message:#{first.id}" in first_refs
    assert "message:#{second.id}" in first_refs
    refute "message:#{later.id}" in first_refs
  end

  test "the database owns a generated simple-config tsvector and partial GIN index" do
    generated =
      Ecto.Adapters.SQL.query!(Repo, """
      SELECT is_generated, generation_expression
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'messages'
        AND column_name = 'search_vector'
      """).rows

    assert [["ALWAYS", expression]] = generated
    assert expression =~ "to_tsvector('simple'"

    indexes =
      Ecto.Adapters.SQL.query!(Repo, """
      SELECT indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND indexname = 'messages_completed_recall_gin_index'
      """).rows

    assert [[index_definition]] = indexes
    assert index_definition =~ "USING gin (search_vector)"
    assert index_definition =~ "status"
    assert index_definition =~ "'complete'"
    assert index_definition =~ "'assistant'"
  end

  test "query, result count, and excerpt sizes are bounded" do
    {:ok, conversation} = Conversations.ensure_conversation("lexical-bounds-browser")
    insert_message(conversation.id, "user", String.duplicate("quasar ", 300), DateTime.utc_now())
    receipt = begin_inference(conversation, "Find quasar.")

    assert {:ok, snapshot} =
             LexicalRecall.load_snapshot(conversation, receipt.memory_snapshot_ref)

    assert {:error, :invalid_recall_query} =
             LexicalRecall.search(conversation, snapshot, String.duplicate("x", 513))

    assert {:error, :invalid_result_limit} =
             LexicalRecall.search(conversation, snapshot, "quasar", first: 11)

    assert {:ok, [match]} = LexicalRecall.search(conversation, snapshot, "quasar", first: 1)
    assert byte_size(match.excerpt) <= 800
    assert match.truncated
  end

  defp begin_inference(conversation, prompt) do
    assert {:ok, records} = Conversations.create_turn(conversation, prompt)
    context = Composer.compose!()

    request = %Request{
      model_id: "recall-test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider")

    inference.receipt
  end

  defp insert_message(conversation_id, role, content, timestamp, status \\ "complete") do
    Repo.insert!(%Message{
      conversation_id: conversation_id,
      role: role,
      content: content,
      status: status,
      inserted_at: timestamp,
      updated_at: timestamp
    })
  end
end
