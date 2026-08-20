defmodule OpenAgents.Persona.SourceManifestTest do
  use ExUnit.Case, async: true
  @moduletag :skip

  alias OpenAgents.Persona.SourceManifest

  test "loads the admitted source manifest" do
    assert {:ok, manifest} = SourceManifest.load()
    assert manifest["id"] == "sarah.persona.sources.v1"
    assert length(manifest["sources"]) == 18
    assert manifest["manifest_sha256"] == SourceManifest.calculate_digest(manifest)

    assert hd(manifest["authority_classes"]) == %{
             "id" => "current_runtime_contracts",
             "persona_input" => false,
             "resolution" => "deployed_release",
             "status" => "binding"
           }
  end

  test "rejects a changed source content digest" do
    manifest = valid_manifest()

    changed_manifest =
      update_source(manifest, "episode-262", fn source ->
        Map.put(source, "content_sha256", String.duplicate("0", 64))
      end)

    assert {:error, :manifest_digest_mismatch} = SourceManifest.validate(changed_manifest)
  end

  test "rejects a missing required source" do
    manifest = valid_manifest()

    changed_manifest =
      Map.update!(manifest, "sources", fn sources ->
        Enum.reject(sources, &(&1["id"] == "episode-260"))
      end)

    assert {:error, {:missing_required_source, "episode-260"}} =
             SourceManifest.validate(changed_manifest)
  end

  test "rejects invalid source status" do
    manifest = valid_manifest()

    changed_manifest =
      update_source(manifest, "episode-262", &Map.put(&1, "status", "probably_canon"))

    assert {:error, {:invalid_source_status, "episode-262", "probably_canon"}} =
             SourceManifest.validate(changed_manifest)
  end

  test "rejects duplicate source IDs and identities" do
    manifest = valid_manifest()
    [first_source | _sources] = manifest["sources"]

    duplicate_id = Map.update!(manifest, "sources", &[first_source | &1])
    assert {:error, :duplicate_source_id} = SourceManifest.validate(duplicate_id)

    duplicate_identity =
      update_source(manifest, "episode-260", fn source ->
        source
        |> Map.put("repository", first_source["repository"])
        |> Map.put("revision", first_source["revision"])
        |> Map.put("path", first_source["path"])
      end)

    assert {:error, :duplicate_source_identity} = SourceManifest.validate(duplicate_identity)
  end

  test "keeps episode 268 out of ordinary voice" do
    manifest = valid_manifest()

    changed_manifest =
      update_source(manifest, "episode-268", fn source ->
        Map.update!(source, "admitted_uses", &["ordinary_voice" | &1])
      end)

    assert {:error, :episode_268_must_remain_scoped} =
             SourceManifest.validate(changed_manifest)
  end

  test "keeps episode 269 classified as founder direction" do
    manifest = valid_manifest()

    changed_manifest =
      update_source(manifest, "episode-269", fn source ->
        Map.update!(source, "admitted_uses", &["ordinary_voice" | &1])
      end)

    assert {:error, :episode_269_must_remain_founder_direction} =
             SourceManifest.validate(changed_manifest)
  end

  test "quarantines episode 263 and pins Omega Alpha by path" do
    manifest = valid_manifest()

    assert {:ok, episode_263} = SourceManifest.source(manifest, "episode-263-conflict")
    assert episode_263["admitted_uses"] == []
    assert episode_263["status"] == "quarantined_catalog_conflict"

    assert {:ok, omega_alpha} = SourceManifest.source(manifest, "omega-alpha-final")
    assert omega_alpha["path"] == "docs/transcripts/26X-omega-alpha.md"
    assert omega_alpha["status"] == "final_spoken_transcript"
  end

  test "rejects a recomputed but unadmitted manifest digest" do
    manifest = valid_manifest()

    changed_manifest =
      update_source(manifest, "episode-262", fn source ->
        Map.put(source, "note", source["note"] <> " Changed.")
      end)

    recomputed_manifest =
      Map.put(
        changed_manifest,
        "manifest_sha256",
        SourceManifest.calculate_digest(changed_manifest)
      )

    assert {:error, :manifest_digest_not_admitted} =
             SourceManifest.validate(recomputed_manifest)
  end

  defp valid_manifest do
    path = :code.priv_dir(:openagents)

    path
    |> List.to_string()
    |> Path.join("sarah/persona/sarah.v1.sources.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp update_source(manifest, source_id, update) do
    Map.update!(manifest, "sources", fn sources ->
      Enum.map(sources, fn source ->
        if source["id"] == source_id, do: update.(source), else: source
      end)
    end)
  end
end
