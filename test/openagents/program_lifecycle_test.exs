defmodule OpenAgents.ProgramLifecycleTest do
  use OpenAgents.DataCase, async: true
  alias OpenAgents.ProgramArtifacts.Reader
  alias OpenAgents.ProgramLifecycle
  alias OpenAgents.ProgramLifecycle.Event

  test "candidate requires independent holdout and complete pinned evaluation" do
    document = candidate_document("candidate.eval.v1")
    assert {:ok, candidate} = ProgramLifecycle.register_candidate(document)

    bad_evaluation = evaluation(document) |> Map.put("cost_complete", false)

    assert {:error, :evaluation_gate_failed} =
             ProgramLifecycle.record_evaluation(candidate.artifact_id, bad_evaluation)

    aliased =
      document
      |> put_in(
        ["datasets", "holdout", "content_digest"],
        document["datasets"]["train"]["content_digest"]
      )
      |> put_digest()

    assert {:error, :true_holdout_not_independent} =
             Reader.read_candidate(Jason.encode!(aliased))

    unconsented =
      document
      |> put_in(["datasets", "train", "source_kind"], "private_production")
      |> put_digest()

    assert {:error, :dataset_manifest_invalid} =
             Reader.read_candidate(Jason.encode!(unconsented))
  end

  test "only explicit humans approve/activate, capture is turn-stable, and rollback is deterministic" do
    first = promote_and_activate("candidate.first", "approved.first", "active.first")
    captured_first = ProgramLifecycle.capture("sarah.memory.intent.v1")
    assert captured_first.artifact.id == "active.first"
    assert captured_first.receipt["activation_generation"] == 1

    document = candidate_document("candidate.second")
    {:ok, candidate} = ProgramLifecycle.register_candidate(document)

    {:ok, _evaluation} =
      ProgramLifecycle.record_evaluation(candidate.artifact_id, evaluation(document))

    assert {:error, :explicit_human_receipt_required} =
             ProgramLifecycle.approve(candidate.artifact_id, %{
               "actor_type" => "optimizer",
               "actor_id" => "optimizer",
               "artifact_id" => "approved.invalid",
               "receipt" => %{"decision" => "self-promote"}
             })

    {:ok, approved} =
      ProgramLifecycle.approve(candidate.artifact_id, human("approved.second", "approve"))

    {:ok, _second_activation} =
      ProgramLifecycle.activate(approved.artifact_id, human("active.second", "activate"))

    captured_second = ProgramLifecycle.capture("sarah.memory.intent.v1")
    assert captured_second.artifact.id == "active.second"
    assert captured_second.receipt["activation_generation"] == 2

    # The value captured before activation remains the exact first artifact.
    assert captured_first.artifact.id == first.artifact_id
    assert captured_first.artifact.digest == first.artifact_digest

    {:ok, rollback} =
      ProgramLifecycle.rollback(
        "sarah.memory.intent.v1",
        human("rollback-receipt", "rollback")
      )

    assert rollback.artifact_id == "active.first"
    assert rollback.generation == 3
    assert ProgramLifecycle.capture("sarah.memory.intent.v1").artifact.id == "active.first"

    events = Repo.all(from(event in Event, order_by: [asc: event.inserted_at]))

    assert Enum.map(events, & &1.event_type) == [
             "compiled",
             "evaluated",
             "approved",
             "activated",
             "compiled",
             "evaluated",
             "approved",
             "activated",
             "rolled_back"
           ]

    assert Enum.all?(
             Enum.filter(events, &(&1.event_type in ~w(approved activated rolled_back))),
             &(&1.actor_type == "human")
           )
  end

  test "approval cannot precede passing evaluation and first activation cannot roll back" do
    document = candidate_document("candidate.no-eval")
    {:ok, candidate} = ProgramLifecycle.register_candidate(document)

    assert {:error, :passing_evaluation_missing} =
             ProgramLifecycle.approve(candidate.artifact_id, human("approved.no-eval", "approve"))

    _first = promote_and_activate("candidate.only", "approved.only", "active.only")

    assert {:error, :no_rollback_predecessor} =
             ProgramLifecycle.rollback(
               "sarah.memory.intent.v1",
               human("rollback-none", "rollback")
             )
  end

  defp promote_and_activate(candidate_id, approved_id, active_id) do
    document = candidate_document(candidate_id)
    {:ok, candidate} = ProgramLifecycle.register_candidate(document)

    {:ok, _evaluation} =
      ProgramLifecycle.record_evaluation(candidate.artifact_id, evaluation(document))

    {:ok, approved} =
      ProgramLifecycle.approve(candidate.artifact_id, human(approved_id, "approve"))

    {:ok, activation} =
      ProgramLifecycle.activate(approved.artifact_id, human(active_id, "activate"))

    activation
  end

  defp candidate_document(artifact_id) do
    document =
      "priv/sarah/programs/memory-intent.shadow.v1.json"
      |> File.read!()
      |> Jason.decode!()

    document
    |> Map.put("artifact_id", artifact_id)
    |> Map.put("artifact_digest", String.duplicate("0", 64))
    |> Map.put("approval", %{"status" => "pending", "receipt" => %{"queue" => "test"}})
    |> Map.put("activation_status", "candidate")
    |> Map.put("predecessor", nil)
    |> put_digest()
  end

  defp evaluation(document) do
    %{
      "passed" => true,
      "safety_passed" => true,
      "privacy_passed" => true,
      "cost_complete" => true,
      "actual_cost_usd" => 2.50,
      "evaluator_id" => document["evaluator"]["id"],
      "evaluator_digest" => document["evaluator"]["digest"],
      "holdout_id" => document["datasets"]["holdout"]["id"],
      "holdout_digest" => document["datasets"]["holdout"]["content_digest"],
      "baseline_metrics" => %{"accuracy" => 0.8},
      "candidate_metrics" => %{"accuracy" => 0.9},
      "uncertainty" => %{"confidence" => 0.95, "half_width" => 0.03}
    }
  end

  defp human(artifact_id, decision) do
    %{
      "actor_type" => "human",
      "actor_id" => "release-owner:test",
      "artifact_id" => artifact_id,
      "receipt" => %{"decision" => decision, "ticket" => "test-review"}
    }
  end

  defp put_digest(document), do: Map.put(document, "artifact_digest", Reader.digest(document))
end
