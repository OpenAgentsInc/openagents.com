defmodule OpenAgents.GraphMemoryTest do
  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.{Conversations, ExperienceMemory, GraphMemory}

  alias OpenAgents.GraphMemory.{
    Artifact,
    Manifest,
    OperationReceipt,
    OutboxEvent,
    SourceMembership
  }

  setup do
    original = Application.fetch_env!(:openagents, :graph_memory)
    Application.put_env(:openagents, :graph_memory, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:openagents, :graph_memory, original) end)
    :ok
  end

  test "replay is deterministic, generation cutover is atomic, and dropping the graph loses no source" do
    fixture = fixture("graph-replay")
    first = failed_case!(fixture, "Release the service", "Use an immediate rollout")
    second = failed_case!(fixture, "Release the service", "Use a staged rollout")
    pattern!(fixture, [first.id, second.id])

    assert {:ok, first_build} = GraphMemory.rebuild(fixture.owner, fixture.scope)
    assert first_build.manifest.status == "current"
    assert first_build.manifest.node_count > 0
    assert first_build.manifest.edge_count > 0

    assert {:ok, replay} = GraphMemory.replay(fixture.owner, fixture.scope)
    assert replay.manifest.generation == first_build.manifest.generation + 1
    assert replay.manifest.source_snapshot_digest == first_build.manifest.source_snapshot_digest
    assert replay.manifest.build_digest == first_build.manifest.build_digest
    assert Repo.get!(Manifest, first_build.manifest.id).status == "retired"

    assert Repo.aggregate(
             from(m in Manifest,
               where:
                 m.owner_visitor_id == ^fixture.owner.id and m.work_scope == ^fixture.scope and
                   m.status == "current"
             ),
             :count
           ) == 1

    artifact_count =
      Repo.aggregate(
        from(a in Artifact, where: a.manifest_id == ^replay.manifest.id),
        :count
      )

    membership_artifacts =
      Repo.all(
        from(m in SourceMembership,
          where: m.manifest_id == ^replay.manifest.id,
          select: m.artifact_id,
          distinct: true
        )
      )

    assert length(membership_artifacts) == artifact_count
    source_record_count = Repo.aggregate(OpenAgents.ExperienceMemory.Record, :count)

    incomplete =
      %Manifest{}
      |> Manifest.create_changeset(%{
        owner_visitor_id: fixture.owner.id,
        work_scope: fixture.scope,
        generation: replay.manifest.generation + 1,
        status: "building",
        policy_id: "sarah.graph.derived.v1",
        policy_version: 1,
        source_snapshot_digest: replay.manifest.source_snapshot_digest,
        node_count: 0,
        edge_count: 0
      })
      |> Repo.insert!()

    assert {:ok, %{recovered: 1, receipts: [recovery]}} =
             GraphMemory.recover(fixture.owner, fixture.scope)

    assert Repo.get!(Manifest, incomplete.id).status == "failed"
    assert recovery.operation == "recover"

    assert {:ok, drop_receipt} = GraphMemory.drop_derived_scope(fixture.owner, fixture.scope)
    assert drop_receipt.operation == "drop"
    assert Repo.aggregate(Manifest, :count) == 0
    assert Repo.aggregate(OpenAgents.ExperienceMemory.Record, :count) == source_record_count

    assert {:ok, rebuilt} = GraphMemory.rebuild(fixture.owner, fixture.scope)
    assert rebuilt.manifest.build_digest == replay.manifest.build_digest
  end

  test "traversal is bounded, source-policy checked, and cannot cross owner scope" do
    fixture = fixture("graph-traverse")
    failed = failed_case!(fixture, "Investigate latency", "Inspect the request trace")
    requested = create_case!(fixture, "Unfinished private work", "Do not recall this yet")
    assert {:ok, build} = GraphMemory.rebuild(fixture.owner, fixture.scope)
    assert {:ok, exported} = GraphMemory.export(fixture.owner, fixture.scope)

    failed_node =
      Enum.find(exported["artifacts"], fn item ->
        item["kind"] == "node" and item["identity_key"] == "experience:#{failed.id}"
      end)

    requested_node =
      Enum.find(exported["artifacts"], fn item ->
        item["kind"] == "node" and item["identity_key"] == "experience:#{requested.id}"
      end)

    assert {:ok, traversal} =
             GraphMemory.traverse(fixture.owner, fixture.scope, failed_node["artifact_id"],
               depth: 2,
               limit: 7
             )

    assert length(traversal["artifacts"]) <= 7
    assert Enum.all?(traversal["artifacts"], &(&1["source_refs"] != []))

    assert {:error, :source_policy_excluded} =
             GraphMemory.traverse(
               fixture.owner,
               fixture.scope,
               requested_node["artifact_id"]
             )

    other = fixture("graph-other-owner")

    assert {:error, :scope_refused} =
             GraphMemory.traverse(
               other.owner,
               fixture.scope,
               failed_node["artifact_id"]
             )

    assert build.manifest.policy_id == "sarah.graph.derived.v1"
  end

  test "source mutations emit an atomic outbox and rebuild consumes the pinned scope" do
    fixture = fixture("graph-outbox")
    record = create_case!(fixture, "Prepare a report", "Collect bounded evidence")

    event =
      Repo.one!(
        from(o in OutboxEvent,
          where: o.source_ref == ^"experience:#{record.id}" and o.operation == "insert"
        )
      )

    assert event.status == "pending"
    assert event.source_digest == record.content_digest
    assert {:ok, build} = GraphMemory.rebuild(fixture.owner, fixture.scope)

    consumed = Repo.get!(OutboxEvent, event.id)
    assert consumed.status == "consumed"
    assert consumed.consumed_manifest_id == build.manifest.id
    assert consumed.consumed_at

    assert {:ok, _running} =
             ExperienceMemory.start_case(fixture.owner, record.id, record.generation)

    assert {:error, :graph_unavailable} = GraphMemory.export(fixture.owner, fixture.scope)
    assert {:ok, refreshed} = GraphMemory.replay(fixture.owner, fixture.scope)
    assert refreshed.manifest.generation == build.manifest.generation + 1
  end

  test "cascade dry-run is exact and completion retires the affected generation" do
    fixture = fixture("graph-cascade")
    first = failed_case!(fixture, "Diagnose a timeout", "Inspect connection evidence")
    second = failed_case!(fixture, "Diagnose another timeout", "Inspect connection evidence")
    pattern!(fixture, [first.id, second.id])
    assert {:ok, build} = GraphMemory.rebuild(fixture.owner, fixture.scope)

    assert {:ok, plan} =
             GraphMemory.plan_cascade(fixture.owner, fixture.scope, "experience:#{first.id}")

    assert plan.status == "planned"
    assert plan.artifact_ids != []
    assert plan.node_count + plan.edge_count == length(plan.artifact_ids)

    assert {:error, :source_still_authoritative} =
             GraphMemory.apply_cascade(fixture.owner, plan.id)

    assert {:ok, _deletion} = ExperienceMemory.delete(fixture.owner, first.id, "owner_requested")
    assert {:ok, receipt} = GraphMemory.apply_cascade(fixture.owner, plan.id)
    assert receipt.operation == "cascade"
    assert receipt.deleted_node_count == plan.node_count
    assert receipt.deleted_edge_count == plan.edge_count
    assert Repo.get!(Manifest, build.manifest.id).status == "retired"

    refute Repo.exists?(
             from(a in Artifact,
               where: a.manifest_id == ^build.manifest.id and a.artifact_id in ^plan.artifact_ids
             )
           )

    assert Repo.aggregate(OperationReceipt, :count) >= 2

    assert {:ok, rebuilt} = GraphMemory.rebuild(fixture.owner, fixture.scope)
    assert rebuilt.manifest.source_snapshot_digest != build.manifest.source_snapshot_digest
    assert {:ok, exported} = GraphMemory.export(fixture.owner, fixture.scope)
    refute Enum.any?(exported["artifacts"], &("experience:#{first.id}" in &1["source_refs"]))
  end

  test "relationship benefit fixture keeps the derived index disabled by default" do
    path =
      Path.join(:code.priv_dir(:openagents), "sarah/evals/graph/relationship-benefit.v1.json")

    evaluation = path |> File.read!() |> Jason.decode!()
    assert evaluation["activation_gate"]["default_enabled"] == false
    assert evaluation["activation_gate"]["requires_material_relationship_benefit"] == true
    assert evaluation["activation_gate"]["requires_source_record_fallback"] == true
  end

  defp fixture(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)

    assert {:ok, records} =
             Conversations.create_turn(conversation, "Authoritative source evidence.")

    %{
      owner: owner,
      conversation: conversation,
      source_message: records.user_message,
      scope: "conversation:#{conversation.id}"
    }
  end

  defp create_case!(fixture, objective, approach) do
    assert {:ok, record} =
             ExperienceMemory.create_case(fixture.owner, fixture.scope, %{
               "objective" => objective,
               "approach" => approach,
               "applicability" => "Only similar work in this conversation",
               "confidence_millis" => 600,
               "source_refs" => ["message:#{fixture.source_message.id}"],
               "trace_refs" => []
             })

    record
  end

  defp failed_case!(fixture, objective, approach) do
    record = create_case!(fixture, objective, approach)

    assert {:ok, running} =
             ExperienceMemory.start_case(fixture.owner, record.id, record.generation)

    assert {:ok, failed} =
             ExperienceMemory.complete_case(fixture.owner, running.id, running.generation, %{
               "outcome_state" => "failed",
               "outcome" => "The scoped objective was not achieved.",
               "target_receipt_refs" => []
             })

    failed
  end

  defp pattern!(fixture, support_ids) do
    assert {:ok, pattern} =
             ExperienceMemory.create_pattern(fixture.owner, fixture.scope, %{
               "phenomenon" => "Related attempts expose a reusable relationship",
               "applicability" => "Only the represented work scope",
               "expected_effect" => "Relationship traversal finds supporting cases",
               "confidence_millis" => 650,
               "support_record_ids" => support_ids
             })

    pattern
  end
end
