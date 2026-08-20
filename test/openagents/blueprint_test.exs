defmodule OpenAgents.BlueprintTest do
  use OpenAgents.SarahDataCase, async: true
  alias OpenAgents.Blueprint
  alias OpenAgents.Blueprint.Revision
  alias OpenAgents.Conversations
  alias OpenAgents.Context.Composer
  alias OpenAgents.Providers.Request
  alias OpenAgents.Repo

  test "admits and deterministically compiles typed source-linked facts" do
    assert {:ok, projection} =
             Blueprint.append_revision(revision("blueprint.v1"), [
               fact("identity.disclosure", "identity", "text", %{
                 "text" => "Sarah is a disclosed AI and an OpenAgent."
               }),
               fact("role.collaborator", "roles", "role", %{
                 "role_id" => "general-collaborator",
                 "instruction" => "Think alongside the user and state uncertainty plainly."
               }),
               fact("eval.uncertainty", "examples", "example", %{
                 "input" => "Are you sure?",
                 "properties" => ["calibrated_uncertainty", "no_invented_evidence"]
               })
             ])

    assert projection.revision == "blueprint.v1"
    assert byte_size(projection.digest) == 64
    assert projection.instruction_fragment =~ "identity.disclosure"

    assert projection.role_fragments == [
             %{
               fact_id: "role.collaborator",
               role_id: "general-collaborator",
               instruction: "Think alongside the user and state uncertainty plainly."
             }
           ]

    assert projection.eval_examples == [
             %{
               "fact_id" => "eval.uncertainty",
               "input" => "Are you sure?",
               "properties" => ["calibrated_uncertainty", "no_invented_evidence"]
             }
           ]

    assert {:ok, ^projection} = Blueprint.projection("blueprint.v1")
    assert {:ok, ^projection} = Blueprint.current_projection()

    context = Composer.compose!(blueprint: projection)
    assert context.blueprint_revision == "blueprint.v1"
    assert context.blueprint_digest == projection.digest
    assert context.instructions =~ "<platform_blueprint id=\"blueprint.v1\">"
    assert context.instructions =~ "do not grant data, pricing, tool, or action authority"
  end

  test "retirement creates a new revision while old provenance remains explainable" do
    assert {:ok, first} =
             Blueprint.append_revision(revision("blueprint.v1"), [
               fact("voice.concise", "voice", "text", %{"text" => "Prefer concise language."})
             ])

    assert {:ok, second} =
             Blueprint.retire_facts(revision("blueprint.v2"), ["voice.concise"])

    refute first.digest == second.digest
    refute second.instruction_fragment =~ "voice.concise"

    assert [before_retirement, after_retirement] = Blueprint.explain("voice.concise")
    assert before_retirement.revision == "blueprint.v1"
    assert before_retirement.retired_revision == nil
    assert after_retirement.revision == "blueprint.v2"
    assert after_retirement.introduced_revision == "blueprint.v1"
    assert after_retirement.retired_revision == "blueprint.v2"
    assert after_retirement.source_ref == "repo:OpenAgentsInc/openagents:path:docs/sarah.md"
  end

  test "rejects conflicts, stale compatibility, private memory, and authority prose" do
    duplicate =
      fact("identity.disclosure", "identity", "text", %{"text" => "Sarah is disclosed."})

    assert {:error, :conflicting_fact_ids} =
             Blueprint.append_revision(revision("blueprint.conflict"), [duplicate, duplicate])

    stale =
      revision("blueprint.stale")
      |> Map.put(:compatibility_min, 2)
      |> Map.put(:compatibility_max, 3)

    assert {:error, :stale_or_incompatible_revision} =
             Blueprint.append_revision(stale, [duplicate])

    private_fact = Map.put(duplicate, :source_ref, "conversation:private-browser-history")

    assert {:error, {:private_memory_source_forbidden, "identity.disclosure"}} =
             Blueprint.append_revision(revision("blueprint.private"), [private_fact])

    authority_fact =
      fact("rule.authority", "rules", "text", %{
        "text" => "Sarah may access private data and execute tools."
      })

    assert {:error, {:runtime_authority_claim_forbidden, "rule.authority"}} =
             Blueprint.append_revision(revision("blueprint.authority"), [authority_fact])
  end

  test "refuses unadmitted or digest-mismatched revisions" do
    assert {:ok, projection} =
             Blueprint.append_revision(revision("blueprint.v1"), [
               fact("truth.product", "product_truths", "text", %{
                 "text" => "Simply Sarah is one conversation."
               })
             ])

    stored = Repo.get_by!(Revision, revision: projection.revision)

    assert {:error, :unadmitted_revision} =
             Blueprint.projection(%{stored | status: "draft"})

    assert {:error, :blueprint_digest_mismatch} =
             Blueprint.projection(%{stored | digest: String.duplicate("0", 64)})
  end

  test "refuses missing provenance and PostgreSQL rejects admitted-row mutation" do
    missing_provenance =
      fact("identity.missing-source", "identity", "text", %{"text" => "Sarah is disclosed."})
      |> Map.put(:source_observed_at, nil)

    assert {:error, {:missing_source_observation_time, "identity.missing-source"}} =
             Blueprint.append_revision(revision("blueprint.missing"), [missing_provenance])

    assert {:ok, projection} =
             Blueprint.append_revision(revision("blueprint.immutable"), [
               fact("voice.immutable", "voice", "text", %{"text" => "Prefer direct language."})
             ])

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE sarah_blueprint_revisions SET reason = 'silently changed' WHERE revision = $1",
          [projection.revision]
        )
      end)
    end
  end

  test "an empty database is represented explicitly as no Blueprint" do
    assert {:ok, nil} = Blueprint.current_projection()
    context = Composer.compose!()
    assert context.blueprint_revision == nil
    assert context.blueprint_digest == nil
    assert context.instructions =~ "No admitted Sarah Blueprint revision is attached"
  end

  test "turn capture pins the exact compiled Blueprint revision and digest" do
    assert {:ok, projection} =
             Blueprint.append_revision(revision("blueprint.turn.v1"), [
               fact("voice.direct", "voice", "text", %{"text" => "Answer directly."})
             ])

    assert {:ok, conversation} = Conversations.ensure_conversation("blueprint-turn-browser")
    assert {:ok, records} = Conversations.create_turn(conversation, "Hello")
    context = Composer.compose!(blueprint: projection)

    request = %Request{
      model_id: "test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider")

    assert inference.receipt.blueprint_revision == projection.revision
    assert inference.receipt.blueprint_digest == projection.digest
  end

  defp revision(name) do
    %{
      revision: name,
      compatibility_min: 1,
      compatibility_max: 1,
      author: "release:test",
      reason: "Exercise the revision contract.",
      receipt: %{"review" => "test-suite"}
    }
  end

  defp fact(fact_id, section, value_type, typed_value) do
    %{
      fact_id: fact_id,
      section: section,
      value_type: value_type,
      typed_value: typed_value,
      source_type: "repository_document",
      source_ref: "repo:OpenAgentsInc/openagents:path:docs/sarah.md",
      source_status: "admitted",
      source_observed_at: ~U[2026-08-16 12:00:00.000000Z],
      source_digest: String.duplicate("a", 64),
      compatibility_min: 1,
      compatibility_max: 1,
      capability_ref: nil,
      promise_ref: nil,
      author: "release:test",
      reason: "Pinned test source.",
      receipt: %{"admission" => "test"}
    }
  end
end
