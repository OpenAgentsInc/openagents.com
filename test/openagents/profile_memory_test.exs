defmodule OpenAgents.ProfileMemoryTest do
  use OpenAgents.DataCase
  alias OpenAgents.{Conversations, ProfileMemory, Repo}
  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.ProfileMemory.Source

  test "conversation repetition never creates or activates a profile record" do
    {owner, conversation} = owner("profile-no-passive-learning")

    for index <- 1..3 do
      source_message(conversation, "I like concise answers repetition #{index}.")
    end

    assert {:ok, []} = ProfileMemory.list_current(owner)
    assert {:ok, export} = ProfileMemory.export(owner)
    assert export["records"] == []

    source = source_message(conversation, "Please remember that I like concise answers.")
    assert {:ok, candidate} = ProfileMemory.create_candidate(owner, attributes(source))
    assert candidate.status == "candidate"
    assert candidate.claim == "I prefer concise answers."
    assert {:ok, []} = ProfileMemory.list_current(owner)

    assert {:ok, active} =
             ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")

    assert active.status == "active"
    assert active.generation == candidate.generation + 1
    assert {:ok, [listed]} = ProfileMemory.list_current(owner)
    assert listed.id == active.id
    assert Enum.map(listed.sources, & &1.message_id) == [source.id]
  end

  test "owner scope is mandatory for reads, sources, mutations, snapshots, and export" do
    {first_owner, first_conversation} = owner("profile-first-browser")
    {second_owner, second_conversation} = owner("profile-second-browser")
    first_source = source_message(first_conversation, "Remember my private project is Atlas.")
    second_source = source_message(second_conversation, "Remember my private project is Beacon.")

    {:ok, first_candidate} =
      ProfileMemory.create_candidate(
        first_owner,
        attributes(first_source, claim: "My project is Atlas.")
      )

    {:ok, first_active} =
      ProfileMemory.transition(
        first_owner,
        first_candidate.id,
        first_candidate.generation,
        "active"
      )

    assert {:error, :not_found} = ProfileMemory.get(second_owner, first_active.id)

    assert {:error, :not_found} =
             ProfileMemory.transition(
               second_owner,
               first_active.id,
               first_active.generation,
               "forgotten"
             )

    assert {:error, :invalid_source} =
             ProfileMemory.create_candidate(second_owner, attributes(first_source))

    assert {:ok, second_candidate} =
             ProfileMemory.create_candidate(
               second_owner,
               attributes(second_source, claim: "My project is Beacon.")
             )

    assert {:ok, first_snapshot} = ProfileMemory.capture_snapshot(first_owner)
    assert {:ok, ^first_snapshot} = ProfileMemory.load_snapshot(first_owner, first_snapshot.ref)

    assert {:error, :scope_refused} =
             ProfileMemory.load_snapshot(second_owner, first_snapshot.ref)

    assert {:error, :scope_refused} = ProfileMemory.list_active(second_owner, first_snapshot)

    forged = %{first_snapshot | captured_at: DateTime.add(first_snapshot.captured_at, 1, :second)}
    assert {:error, :scope_refused} = ProfileMemory.list_active(first_owner, forged)
    assert {:ok, second_export} = ProfileMemory.export(second_owner)
    assert Enum.map(second_export["records"], & &1["id"]) == [second_candidate.id]
    refute inspect(second_export) =~ first_active.id
    refute inspect(second_export) =~ "Atlas"
  end

  test "the lifecycle matrix is explicit and optimistic generations reject stale writes" do
    assert ProfileMemory.transitions() == %{
             "candidate" => ~w(active forgotten expired),
             "active" => ~w(superseded forgotten expired),
             "superseded" => [],
             "forgotten" => [],
             "expired" => []
           }

    {owner, _conversation} = owner("profile-lifecycle-browser")
    {:ok, candidate} = ProfileMemory.create_candidate(owner, asserted_attributes())

    assert {:error, :invalid_memory_transition} =
             ProfileMemory.transition(owner, candidate.id, candidate.generation, "superseded")

    assert {:ok, active} =
             ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")

    assert {:error, :stale_generation} =
             ProfileMemory.transition(owner, active.id, candidate.generation, "forgotten")

    assert {:ok, forgotten} =
             ProfileMemory.transition(owner, active.id, active.generation, "forgotten")

    assert {:error, :invalid_memory_transition} =
             ProfileMemory.transition(owner, forgotten.id, forgotten.generation, "active")
  end

  test "correction supersedes immutable history while a frozen snapshot stays stable" do
    {owner, conversation} = owner("profile-correction-browser")
    old_source = source_message(conversation, "Remember that my project is called Old Name.")
    new_source = source_message(conversation, "Correction: remember that it is called One.")

    {:ok, candidate} =
      ProfileMemory.create_candidate(
        owner,
        attributes(old_source, category: "project", claim: "My project is called Old Name.")
      )

    {:ok, old_active} =
      ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")

    {:ok, frozen} = ProfileMemory.capture_snapshot(owner)

    correction =
      Task.async(fn ->
        ProfileMemory.correct(
          owner,
          old_active.id,
          old_active.generation,
          attributes(new_source, category: "project", claim: "My project is called One.")
        )
      end)

    assert {:ok, %{superseded: superseded, replacement: replacement}} = Task.await(correction)
    assert superseded.status == "superseded"
    assert superseded.claim == "My project is called Old Name."
    assert replacement.status == "active"
    assert replacement.supersedes_record_id == superseded.id

    assert {:ok, [historical_view]} = ProfileMemory.list_active(owner, frozen)
    assert historical_view.id == superseded.id
    assert historical_view.claim == "My project is called Old Name."

    assert {:ok, [current_view]} = ProfileMemory.list_current(owner)
    assert current_view.id == replacement.id
    assert current_view.claim == "My project is called One."
  end

  test "deduplication and singleton conflicts require explicit correction" do
    {owner, _conversation} = owner("profile-conflict-browser")
    {:ok, first} = ProfileMemory.create_candidate(owner, asserted_attributes())
    {:ok, _active} = ProfileMemory.transition(owner, first.id, first.generation, "active")

    {:ok, duplicate} = ProfileMemory.create_candidate(owner, asserted_attributes())

    assert {:error, :duplicate_memory} =
             ProfileMemory.transition(owner, duplicate.id, duplicate.generation, "active")

    {:ok, name_one} =
      ProfileMemory.create_candidate(
        owner,
        asserted_attributes(category: "name", claim: "My name is Ada.")
      )

    {:ok, _active_name} =
      ProfileMemory.transition(owner, name_one.id, name_one.generation, "active")

    {:ok, name_two} =
      ProfileMemory.create_candidate(
        owner,
        asserted_attributes(category: "name", claim: "My name is Grace.")
      )

    assert {:error, :memory_conflict_requires_correction} =
             ProfileMemory.transition(owner, name_two.id, name_two.generation, "active")
  end

  test "non-singleton active category limits are deterministic" do
    {owner, _conversation} = owner("profile-category-limit-browser")

    for index <- 1..25 do
      {:ok, candidate} =
        ProfileMemory.create_candidate(
          owner,
          asserted_attributes(category: "project", claim: "Project memory #{index}.")
        )

      assert {:ok, _active} =
               ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")
    end

    {:ok, overflow} =
      ProfileMemory.create_candidate(
        owner,
        asserted_attributes(category: "project", claim: "Project memory overflow.")
      )

    assert {:error, :memory_category_limit_reached} =
             ProfileMemory.transition(owner, overflow.id, overflow.generation, "active")
  end

  test "expiry is explicit, old snapshots remain stable, and purge removes all derived links" do
    {owner, conversation} = owner("profile-expiry-browser")
    source = source_message(conversation, "Remember the temporary launch preference.")
    expires_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {:ok, candidate} =
      ProfileMemory.create_candidate(owner, attributes(source, expires_at: expires_at))

    {:ok, active} =
      ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")

    {:ok, frozen} = ProfileMemory.capture_snapshot(owner)
    assert {:ok, 1} = ProfileMemory.expire_due(owner, DateTime.add(expires_at, 1, :second))
    assert {:ok, [historical]} = ProfileMemory.list_active(owner, frozen)
    assert historical.id == active.id
    assert historical.status == "active"
    assert {:ok, []} = ProfileMemory.list_current(owner)

    {:ok, expired} = ProfileMemory.get(owner, active.id)
    assert expired.status == "expired"

    assert Repo.aggregate(
             from(link in Source, where: link.memory_record_id == ^active.id),
             :count
           ) == 1

    assert {:ok, :purged} = ProfileMemory.purge(owner, expired.id, expired.generation)
    assert {:error, :not_found} = ProfileMemory.get(owner, expired.id)

    assert Repo.aggregate(
             from(link in Source, where: link.memory_record_id == ^active.id),
             :count
           ) == 0

    assert Repo.get(Message, source.id)
  end

  test "bounds and model provenance are enforced before persistence" do
    {owner, _conversation} = owner("profile-bounds-browser")

    assert {:error, :invalid_claim} =
             ProfileMemory.create_candidate(
               owner,
               asserted_attributes(claim: String.duplicate("x", 501))
             )

    assert {:error, :invalid_memory_attributes} =
             ProfileMemory.create_candidate(owner, asserted_attributes(category: "secret"))

    assert {:error, :missing_model_provenance} =
             ProfileMemory.create_candidate(owner, %{
               category: "preference",
               claim: "A model-proposed candidate.",
               creator: "model_proposal",
               provenance: %{},
               sources: []
             })

    assert {:ok, model_candidate} =
             ProfileMemory.create_candidate(owner, %{
               category: "preference",
               claim: "A model-proposed candidate.",
               creator: "model_proposal",
               provenance: %{"model_id" => "eval-model"},
               creator_artifact_id: "artifact-v1",
               creator_artifact_digest: String.duplicate("a", 64),
               sources: []
             })

    assert model_candidate.status == "candidate"

    assert {:error, :active_memory_requires_support} =
             ProfileMemory.transition(
               owner,
               model_candidate.id,
               model_candidate.generation,
               "active"
             )
  end

  test "database backstops reject orphan activation, source deletion, and in-place claim edits" do
    {owner, conversation} = owner("profile-database-constraints")
    {_foreign_owner, foreign_conversation} = owner("profile-database-foreign-source")
    source = source_message(conversation, "Remember this database-backed preference.")
    foreign_source = source_message(foreign_conversation, "A different browser's private source.")
    {:ok, candidate} = ProfileMemory.create_candidate(owner, attributes(source))
    {:ok, active} = ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")
    {:ok, snapshot} = ProfileMemory.capture_snapshot(owner)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE profile_memory_records SET claim = 'silently edited' WHERE id::text = $1",
          [active.id]
        )
      end)
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Repo.insert!(
          Source.changeset(%Source{}, %{
            memory_record_id: active.id,
            message_id: foreign_source.id,
            source_kind: "owner_statement",
            inserted_at: DateTime.utc_now()
          })
        )
      end)
    end

    snapshot_id = String.replace_prefix(snapshot.ref, "profile-memory-snapshot:v1:", "")

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE profile_memory_snapshots SET captured_at = now() WHERE id::text = $1",
          [snapshot_id]
        )
      end)
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Repo.delete_all(from(link in Source, where: link.memory_record_id == ^active.id))

        Ecto.Adapters.SQL.query!(
          Repo,
          "SET CONSTRAINTS profile_memory_source_delete_support_trigger IMMEDIATE",
          []
        )
      end)
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        insert_orphan_active!(owner.id)

        Ecto.Adapters.SQL.query!(
          Repo,
          "SET CONSTRAINTS profile_memory_record_support_trigger IMMEDIATE",
          []
        )
      end)
    end
  end

  defp owner(browser_key) do
    {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    {Repo.get!(Visitor, conversation.visitor_id), conversation}
  end

  defp source_message(conversation, content) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: "user",
      content: content,
      status: "complete"
    })
  end

  defp attributes(source, overrides \\ []) do
    Map.merge(
      %{
        category: "preference",
        claim: "  I   prefer concise answers.  ",
        creator: "user_explicit",
        provenance: %{"intent" => "remember"},
        sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}]
      },
      Map.new(overrides)
    )
  end

  defp asserted_attributes(overrides \\ []) do
    Map.merge(
      %{
        category: "preference",
        claim: "I prefer concise answers.",
        creator: "user_explicit",
        provenance: %{"intent" => "remember"},
        owner_asserted: true,
        sources: []
      },
      Map.new(overrides)
    )
  end

  defp insert_orphan_active!(owner_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO profile_memory_records (
        id, owner_visitor_id, schema_version, category, claim, claim_fingerprint,
        status, provenance, confidence, redaction_policy, creator, generation,
        created_generation, active_generation, inserted_at, updated_at
      ) VALUES ($1, $2, 1, 'other', 'Orphan active claim.', $3, 'active', '{}',
        1, 'sarah.memory.redaction.pending.v1', 'user_explicit', 1, 1, 1, $4, $4)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(owner_id),
        :crypto.hash(:sha256, "orphan"),
        DateTime.utc_now()
      ]
    )
  end
end
