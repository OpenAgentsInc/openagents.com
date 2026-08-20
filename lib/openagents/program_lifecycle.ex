defmodule OpenAgents.ProgramLifecycle do
  @moduledoc "Governed offline evaluation, human promotion, activation, and rollback."

  import Ecto.Query

  alias OpenAgents.ProgramArtifacts
  alias OpenAgents.ProgramArtifacts.{Reader, Snapshot}
  alias OpenAgents.ProgramLifecycle.{Activation, ArtifactRecord, Event}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  def register_candidate(document) when is_map(document) do
    with {:ok, artifact} <- Reader.read_candidate(Jason.encode!(document)) do
      Repo.transaction(fn ->
        record = insert_artifact!(artifact, "candidate")

        insert_event!(%{
          artifact_id: artifact.id,
          signature_id: artifact.signature_id,
          event_type: "compiled",
          actor_type: "compiler",
          actor_id: document["provenance"]["compiled_by"],
          receipt: document["provenance"]["receipt"]
        })

        record
      end)
      |> unwrap()
    end
  end

  def record_evaluation(candidate_artifact_id, evaluation) when is_map(evaluation) do
    Repo.transaction(fn ->
      candidate = get_artifact!(candidate_artifact_id, "candidate")
      validate_evaluation!(candidate.document, evaluation)

      insert_event!(%{
        artifact_id: candidate.artifact_id,
        signature_id: candidate.signature_id,
        event_type: "evaluated",
        actor_type: "evaluator",
        actor_id: evaluation["evaluator_id"],
        receipt: evaluation
      })
    end)
    |> unwrap()
  end

  def approve(candidate_artifact_id, human) when is_map(human) do
    Repo.transaction(fn ->
      validate_human!(human)
      candidate = get_artifact!(candidate_artifact_id, "candidate")
      _evaluation = passing_evaluation!(candidate.artifact_id)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      document =
        candidate.document
        |> Map.put("artifact_id", human["artifact_id"])
        |> Map.put("artifact_digest", String.duplicate("0", 64))
        |> Map.put("approval", %{
          "status" => "approved",
          "approved_by" => human["actor_id"],
          "approved_at" => now,
          "receipt" => human["receipt"]
        })
        |> Map.put("activation_status", "shadow")
        |> put_digest()

      artifact = read_admitted!(document)
      record = insert_artifact!(artifact, "approved")

      insert_event!(%{
        artifact_id: artifact.id,
        signature_id: artifact.signature_id,
        event_type: "approved",
        actor_type: "human",
        actor_id: human["actor_id"],
        receipt: human["receipt"],
        previous_artifact_id: candidate.artifact_id
      })

      record
    end)
    |> unwrap()
  end

  def activate(approved_artifact_id, human) when is_map(human) do
    Repo.transaction(fn ->
      validate_human!(human)
      approved = get_artifact!(approved_artifact_id, "approved")
      current = Repo.get_for_update(Activation, approved.signature_id)

      document =
        approved.document
        |> Map.put("artifact_id", human["artifact_id"])
        |> Map.put("artifact_digest", String.duplicate("0", 64))
        |> Map.put("activation_status", "active")
        |> Map.put("predecessor", current && current.artifact_id)
        |> put_digest()

      artifact = read_admitted!(document)
      _record = insert_artifact!(artifact, "active")

      event =
        insert_event!(%{
          artifact_id: artifact.id,
          signature_id: artifact.signature_id,
          event_type: "activated",
          actor_type: "human",
          actor_id: human["actor_id"],
          receipt: human["receipt"],
          previous_artifact_id: current && current.artifact_id
        })

      generation = if current, do: current.generation + 1, else: 1

      activation_changeset =
        Activation.changeset(current || %Activation{signature_id: artifact.signature_id}, %{
          artifact_id: artifact.id,
          artifact_digest: artifact.digest,
          generation: generation,
          activation_event_id: event.id
        })

      if current, do: Repo.update!(activation_changeset), else: Repo.insert!(activation_changeset)
    end)
    |> unwrap()
  end

  def rollback(signature_id, human) when is_binary(signature_id) and is_map(human) do
    Repo.transaction(fn ->
      validate_human!(human)

      current =
        Repo.get_for_update(Activation, signature_id) ||
          Repo.rollback(:no_active_artifact)

      current_record = get_artifact!(current.artifact_id, "active")

      predecessor_id =
        current_record.predecessor_artifact_id || Repo.rollback(:no_rollback_predecessor)

      predecessor = Repo.get_by!(ArtifactRecord, artifact_id: predecessor_id)

      event =
        insert_event!(%{
          artifact_id: predecessor.artifact_id,
          signature_id: signature_id,
          event_type: "rolled_back",
          actor_type: "human",
          actor_id: human["actor_id"],
          receipt: human["receipt"],
          previous_artifact_id: current.artifact_id
        })

      current
      |> Activation.changeset(%{
        artifact_id: predecessor.artifact_id,
        artifact_digest: predecessor.digest,
        generation: current.generation + 1,
        activation_event_id: event.id
      })
      |> Repo.update!()
    end)
    |> unwrap()
  end

  @doc "Captures the active database artifact, or the release-pinned baseline catalog."
  def capture(signature_id) when is_binary(signature_id) do
    case Repo.get(Activation, signature_id) do
      nil -> ProgramArtifacts.capture(signature_id)
      activation -> capture_activation!(activation)
    end
  end

  defp capture_activation!(activation) do
    record = Repo.get_by!(ArtifactRecord, artifact_id: activation.artifact_id)
    artifact = read_admitted!(record.document)

    catalog_digest =
      Canonical.digest!(%{
        "signature_id" => activation.signature_id,
        "generation" => activation.generation,
        "artifact_digest" => artifact.digest
      })

    receipt = %{
      "schema" => "sarah.program_capture.v1",
      "signature_id" => artifact.signature_id,
      "artifact_id" => artifact.id,
      "artifact_digest" => artifact.digest,
      "catalog_digest" => catalog_digest,
      "activation_status" => "active",
      "activation_generation" => activation.generation,
      "degraded" => false,
      "reason" => "governed_active_artifact_captured"
    }

    %Snapshot{
      signature_id: artifact.signature_id,
      artifact: artifact,
      degraded?: false,
      reason: receipt["reason"],
      receipt: receipt
    }
  end

  defp validate_evaluation!(document, evaluation) do
    evaluator = document["evaluator"]
    holdout = document["datasets"]["holdout"]
    budget = document["optimizer"]["budget"]

    valid =
      evaluation["passed"] == true and evaluation["safety_passed"] == true and
        evaluation["privacy_passed"] == true and evaluation["cost_complete"] == true and
        evaluation["evaluator_id"] == evaluator["id"] and
        evaluation["evaluator_digest"] == evaluator["digest"] and
        evaluation["holdout_id"] == holdout["id"] and
        evaluation["holdout_digest"] == holdout["content_digest"] and
        is_number(evaluation["actual_cost_usd"]) and
        evaluation["actual_cost_usd"] <= budget["max_cost_usd"] and
        is_map(evaluation["baseline_metrics"]) and is_map(evaluation["candidate_metrics"]) and
        is_map(evaluation["uncertainty"])

    unless valid, do: Repo.rollback(:evaluation_gate_failed)
  end

  defp passing_evaluation!(artifact_id) do
    Repo.one(
      from(event in Event,
        where: event.artifact_id == ^artifact_id and event.event_type == "evaluated",
        order_by: [desc: event.inserted_at],
        limit: 1
      )
    ) || Repo.rollback(:passing_evaluation_missing)
  end

  defp validate_human!(%{
         "actor_type" => "human",
         "actor_id" => actor_id,
         "artifact_id" => artifact_id,
         "receipt" => receipt
       })
       when is_binary(actor_id) and actor_id != "" and is_binary(artifact_id) and
              artifact_id != "" and is_map(receipt) and map_size(receipt) > 0,
       do: :ok

  defp validate_human!(_human), do: Repo.rollback(:explicit_human_receipt_required)

  defp insert_artifact!(artifact, stage) do
    %ArtifactRecord{}
    |> ArtifactRecord.changeset(%{
      artifact_id: artifact.id,
      signature_id: artifact.signature_id,
      digest: artifact.digest,
      stage: stage,
      predecessor_artifact_id: artifact.predecessor,
      document: artifact.document
    })
    |> Repo.insert!()
  end

  defp insert_event!(attributes), do: %Event{} |> Event.changeset(attributes) |> Repo.insert!()
  defp get_artifact!(id, stage), do: Repo.get_by!(ArtifactRecord, artifact_id: id, stage: stage)
  defp put_digest(document), do: Map.put(document, "artifact_digest", Reader.digest(document))

  defp read_admitted!(document) do
    case Reader.read(Jason.encode!(document)) do
      {:ok, artifact} -> artifact
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
