defmodule OpenAgents.Memory.SemanticTestProvider do
  @behaviour OpenAgents.Memory.EmbeddingProvider

  @impl true
  def embed(text, %{dimensions: 64}) do
    normalized = String.downcase(text)

    concept =
      cond do
        Regex.match?(~r/\b(car|automobile|vehicle)\b/, normalized) -> 0
        Regex.match?(~r/\b(project|roadmap|plan)\b/, normalized) -> 1
        true -> 62
      end

    vector = List.duplicate(0.0, 64) |> List.replace_at(concept, 1.0) |> List.replace_at(63, 0.01)
    {:ok, vector}
  end
end

defmodule OpenAgents.Memory.SemanticFailingProvider do
  @behaviour OpenAgents.Memory.EmbeddingProvider
  @impl true
  def embed(_text, _config), do: {:error, :semantic_provider_offline}
end

defmodule OpenAgents.SemanticRecallTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Message

  alias OpenAgents.Memory.{
    HybridRecall,
    LexicalRecall,
    SemanticDerivativeReceipt,
    SemanticIndex,
    SemanticJob
  }

  setup do
    original = Application.fetch_env!(:openagents, :semantic_index)

    Application.put_env(:openagents, :semantic_index,
      enabled: true,
      provider: OpenAgents.Memory.SemanticTestProvider,
      model_id: "test-semantic-64",
      model_version: "v1",
      dimensions: 64,
      batch_size: 20,
      poll_interval_ms: 60_000
    )

    on_exit(fn -> Application.put_env(:openagents, :semantic_index, original) end)
    manifest = SemanticIndex.ensure_manifest!(manifest_config("v1"))
    %{manifest: manifest, original_semantic_config: original}
  end

  test "outbox indexing is idempotent and hybrid ranking never crosses conversation scope" do
    first = conversation("semantic-first")
    second = conversation("semantic-second")
    car = message(first, "The blue car is parked beside the studio.")
    _foreign = message(second, "The foreign car is outside a private address.")
    marker = message(first, "Snapshot boundary marker.")

    # Each new conversation also has Sarah's authoritative greeting message.
    assert Repo.aggregate(SemanticJob, :count) == 5

    assert %{completed: 5, failed: 0, invalidated: 0} =
             SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)

    assert {:ok, snapshot} = LexicalRecall.load_snapshot(first, "message:#{marker.id}")
    assert {:ok, page} = HybridRecall.search_page(first, snapshot, "automobile", first: 5)
    assert page.strategy == "hybrid_rrf"
    refute page.semantic_degraded
    assert Enum.any?(page.matches, &(&1.source_ref == "message:#{car.id}"))
    refute Enum.any?(page.matches, &String.contains?(&1.excerpt, "private address"))

    _same = car |> Ecto.Changeset.change(content: car.content) |> Repo.update!()
    assert Repo.aggregate(SemanticJob, :count) == 5
    assert Repo.get_by!(SemanticJob, message_id: car.id).status == "completed"
  end

  test "content correction invalidates stale vectors and requeues the authoritative message" do
    conversation = conversation("semantic-correction")
    source = message(conversation, "The car is the preferred transport.")
    _marker = message(conversation, "Marker for correction.")
    assert %{completed: 3} = SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)
    assert embedding_count(source.id) == 1

    corrected =
      source
      |> Ecto.Changeset.change(content: "The bicycle is the preferred transport.")
      |> Repo.update!()

    assert embedding_count(source.id) == 0
    assert Repo.get_by!(SemanticJob, message_id: source.id).status == "pending"

    receipt = Repo.get_by!(SemanticDerivativeReceipt, message_id: source.id)
    assert receipt.action == "invalidate"
    assert receipt.reason_code == "source_content_changed"
    assert receipt.deleted_embedding_count == 1
    refute inspect(receipt) =~ source.content

    assert Repo.get_by!(SemanticJob, message_id: source.id).content_digest ==
             OpenAgents.Provenance.Canonical.sha256(corrected.content)
  end

  test "deletion receipts remove every derivative while leaving the source authoritative" do
    conversation = conversation("semantic-delete")
    source = message(conversation, "The project roadmap mentions a private codename.")
    assert %{completed: 2} = SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)

    assert {:ok, receipt} = SemanticIndex.invalidate(source, "delete", "owner_forget")
    assert receipt.deleted_embedding_count == 1
    assert receipt.invalidated_job_count == 1
    assert embedding_count(source.id) == 0
    assert Repo.get!(Message, source.id).content == source.content
    refute inspect(receipt) =~ source.content
    assert Repo.aggregate(SemanticDerivativeReceipt, :count) == 1
  end

  test "new manifest generations exclude stale vectors until reproducible rebuild completes" do
    conversation = conversation("semantic-generation")
    car = message(conversation, "The car belongs in the west garage.")
    marker = message(conversation, "Generation marker.")
    assert %{completed: 3} = SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)

    assert {:ok, generation_two} = SemanticIndex.install_manifest(manifest_config("v2"))
    assert generation_two.generation == 2
    assert {:ok, snapshot} = LexicalRecall.load_snapshot(conversation, "message:#{marker.id}")

    assert {:ok, degraded} = HybridRecall.search_page(conversation, snapshot, "automobile")
    assert degraded.strategy == "lexical_fallback"
    assert degraded.semantic_degraded

    counts = SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)
    assert counts.completed == 3
    assert {:ok, rebuilt} = HybridRecall.search_page(conversation, snapshot, "automobile")
    assert rebuilt.strategy == "hybrid_rrf"
    assert Enum.any?(rebuilt.matches, &(&1.source_ref == "message:#{car.id}"))
  end

  test "semantic provider failure is observable and preserves exact lexical fallback" do
    conversation = conversation("semantic-degradation")
    source = message(conversation, "The blue archive contains the approved note.")
    marker = message(conversation, "Degradation marker.")
    assert %{completed: 3} = SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)
    assert {:ok, snapshot} = LexicalRecall.load_snapshot(conversation, "message:#{marker.id}")
    assert {:ok, lexical} = LexicalRecall.search_page(conversation, snapshot, "blue")

    config = Application.fetch_env!(:openagents, :semantic_index)

    Application.put_env(
      :openagents,
      :semantic_index,
      Keyword.put(config, :provider, OpenAgents.Memory.SemanticFailingProvider)
    )

    assert {:ok, fallback} = HybridRecall.search_page(conversation, snapshot, "blue")
    assert fallback.strategy == "lexical_fallback"
    assert fallback.semantic_degraded
    assert fallback.semantic_reason == "semantic_provider_offline"

    assert Enum.map(fallback.matches, & &1.source_ref) ==
             Enum.map(lexical.matches, & &1.source_ref)

    assert hd(fallback.matches).source_ref == "message:#{source.id}"
  end

  test "committed hybrid comparison improves synonym recall without weakening the lexical baseline",
       %{original_semantic_config: original} do
    conversation = conversation("semantic-release-eval")
    foreign = conversation("semantic-release-eval-foreign")
    source = message(conversation, "The blue car is parked beside the studio.")
    _foreign_source = message(foreign, "The foreign automobile reveals a private address.")
    marker = message(conversation, "Release evaluation marker.")

    assert %{failed: 0, invalidated: 0} =
             SemanticIndex.process_all(OpenAgents.Memory.SemanticTestProvider)

    assert {:ok, snapshot} = LexicalRecall.load_snapshot(conversation, "message:#{marker.id}")
    assert {:ok, lexical} = LexicalRecall.search_page(conversation, snapshot, "automobile")
    assert {:ok, hybrid} = HybridRecall.search_page(conversation, snapshot, "automobile")

    config = Application.fetch_env!(:openagents, :semantic_index)

    Application.put_env(
      :openagents,
      :semantic_index,
      Keyword.put(config, :provider, OpenAgents.Memory.SemanticFailingProvider)
    )

    assert {:ok, fallback} = HybridRecall.search_page(conversation, snapshot, "automobile")

    measured = %{
      "fallback_lexical_parity" => boolean_score(source_refs(fallback) == source_refs(lexical)),
      "hybrid_synonym_recall" => boolean_score("message:#{source.id}" in source_refs(hybrid)),
      "lexical_synonym_recall" => boolean_score("message:#{source.id}" in source_refs(lexical)),
      "cross_scope_leakage" =>
        Enum.count(hybrid.matches, &String.contains?(&1.excerpt, "private address"))
    }

    expected =
      :openagents
      |> :code.priv_dir()
      |> Path.join("sarah/evals/recall/hybrid-comparison.v1.json")
      |> File.read!()
      |> Jason.decode!()

    assert measured == expected["metrics"]
    refute Keyword.fetch!(original, :enabled)
    assert expected["activation_default"] == "lexical"
  end

  defp conversation(key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(key)
    conversation
  end

  defp message(conversation, content) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: "user",
      content: content,
      status: "complete"
    })
  end

  defp embedding_count(message_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM message_semantic_embeddings WHERE message_id=$1::text::uuid",
        [
          message_id
        ]
      )

    count
  end

  defp source_refs(page), do: Enum.map(page.matches, & &1.source_ref)
  defp boolean_score(true), do: 1.0
  defp boolean_score(false), do: 0.0

  defp manifest_config(version),
    do: %{model_id: "test-semantic-64", model_version: version, dimensions: 64}
end
