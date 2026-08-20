defmodule OpenAgents.ProgramArtifactsTest do
  use ExUnit.Case, async: true
  @moduletag :skip
  alias OpenAgents.ProgramArtifacts
  alias OpenAgents.ProgramArtifacts.Reader

  setup do
    contents = File.read!("priv/sarah/programs/memory-intent.shadow.v1.json")
    document = Jason.decode!(contents)
    {:ok, artifact} = Reader.read(contents)
    %{contents: contents, document: document, artifact: artifact}
  end

  test "reads the complete canonical language-neutral artifact", %{artifact: artifact} do
    assert artifact.id == "sarah.program.memory_intent.shadow.v1"
    assert artifact.signature_id == "sarah.memory.intent.v1"
    assert artifact.activation_status == "shadow"
    assert artifact.predecessor == nil
    assert Reader.digest(artifact.document) == artifact.digest
    assert byte_size(artifact.digest) == 64

    assert artifact.document["signature"]["output_kind"] == "proposal"
    assert artifact.document["compiler"]["version"] == "1.0.0"
    assert artifact.document["model"]["model"] == "gpt-5.6-luna"
    assert artifact.document["datasets"]["holdout"]["purpose"] == "true_holdout"
    assert artifact.document["approval"]["status"] == "approved"
  end

  test "rejects digest mismatch, incompatible runtime, and unapproved status", %{
    document: document
  } do
    assert {:error, :artifact_digest_mismatch} =
             document
             |> put_in(["parameters", "minimum_confidence"], 0.1)
             |> Jason.encode!()
             |> Reader.read()

    assert {:error, :artifact_runtime_incompatible} =
             document
             |> put_in(["compatibility", "runtime_min"], 2)
             |> redigest()
             |> Reader.read()

    assert {:error, :artifact_unapproved} =
             document
             |> put_in(["approval", "status"], "candidate")
             |> redigest()
             |> Reader.read()
  end

  test "training and validation cannot alias true holdout", %{document: document} do
    aliased_holdout =
      document
      |> put_in(
        ["datasets", "holdout", "content_digest"],
        document["datasets"]["train"]["content_digest"]
      )
      |> redigest()

    assert {:error, :true_holdout_not_independent} = Reader.read(aliased_holdout)

    missing_holdout =
      document |> update_in(["datasets"], &Map.delete(&1, "holdout")) |> redigest()

    assert {:error, :true_holdout_missing} = Reader.read(missing_holdout)
  end

  test "program output schemas cannot carry runtime authority", %{document: document} do
    authority_output =
      document
      |> put_in(
        ["signature", "output_schema", "properties", "tool_call"],
        %{"type" => "object"}
      )
      |> redigest()

    assert {:error, :program_output_authority_forbidden} = Reader.read(authority_output)

    exported_functions = Reader.__info__(:functions) |> Enum.map(&elem(&1, 0))
    refute :execute in exported_functions
    refute :promote in exported_functions
    refute :activate in exported_functions
    refute :call_tool in exported_functions
  end

  test "catalog refuses an unknown predecessor or an artifact not explicitly admitted", %{
    artifact: artifact
  } do
    artifact_id = artifact.id

    assert {:error, {:unknown_program_predecessor, ^artifact_id}} =
             ProgramArtifacts.compile_catalog([%{artifact | predecessor: "missing.predecessor"}])

    assert {:error, {:program_artifact_not_admitted, ^artifact_id}} =
             ProgramArtifacts.compile_catalog([
               %{artifact | digest: String.duplicate("0", 64)}
             ])
  end

  test "capture returns an admitted immutable snapshot or an explicit baseline", %{
    artifact: artifact
  } do
    assert {:ok, catalog} = ProgramArtifacts.compile_catalog([artifact])
    selected = ProgramArtifacts.capture(catalog, artifact.signature_id)

    assert selected.artifact == artifact
    refute selected.degraded?
    assert selected.receipt["artifact_digest"] == artifact.digest
    assert selected.receipt["catalog_digest"] == catalog.digest

    degraded = ProgramArtifacts.capture(catalog, "sarah.unknown.signature.v1")
    assert degraded.artifact == nil
    assert degraded.degraded?
    assert degraded.receipt["activation_status"] == "baseline"
    assert degraded.reason == "deterministic_baseline:no_admitted_artifact"

    # Captures are values. Constructing a later catalog cannot mutate what an
    # already-started turn holds.
    later_catalog = %{catalog | by_signature: %{}}
    assert ProgramArtifacts.capture(later_catalog, artifact.signature_id).degraded?
    assert selected.artifact.digest == artifact.digest
    refute selected.degraded?
  end

  test "boot catalog installs only the pinned admitted digest", %{artifact: artifact} do
    catalog = ProgramArtifacts.current!()
    snapshot = ProgramArtifacts.capture(artifact.signature_id)

    assert catalog.by_id[artifact.id].digest == artifact.digest
    assert snapshot.artifact.digest == artifact.digest
  end

  defp redigest(document) do
    document
    |> Map.put("artifact_digest", Reader.digest(document))
    |> Jason.encode!()
  end
end
