defmodule OpenAgents.PersonaTest do
  use ExUnit.Case, async: true
  alias OpenAgents.Persona
  alias OpenAgents.Persona.SourceManifest

  test "installs one admitted persona and greeting" do
    persona = Persona.current!()

    assert persona.id == "sarah.persona.v1"
    assert persona.version == 1
    assert persona.digest == "9c738125c5f4799d2bc7c88f0eb22ce8f979289991612976172ab732e6471227"
    assert persona.greeting == "Hello. I'm Sarah—an OpenAgent. What are we working on?"
    assert persona.source_manifest_id == "sarah.persona.sources.v1"
    assert persona.source_manifest_digest == SourceManifest.load!()["manifest_sha256"]
    assert persona.content =~ "You are Sarah."
    assert persona.content =~ "You are an OpenAgent"
  end

  test "rejects an artifact changed without a new admitted version" do
    manifest = SourceManifest.load!()
    contents = File.read!(persona_path())

    assert {:error, :persona_digest_not_admitted} =
             Persona.from_content(manifest, contents <> "\nChanged in place.\n")
  end

  test "rejects an unadmitted greeting before digest validation" do
    manifest = SourceManifest.load!()

    contents =
      persona_path()
      |> File.read!()
      |> String.replace(
        "Hello. I'm Sarah—an OpenAgent. What are we working on?",
        "Welcome back, old friend."
      )

    assert {:error, :unadmitted_greeting} = Persona.from_content(manifest, contents)
  end

  test "rejects a source manifest that is not itself admitted" do
    manifest = SourceManifest.load!()
    changed_manifest = Map.put(manifest, "manifest_sha256", String.duplicate("0", 64))

    assert {:error, {:invalid_source_manifest, :manifest_digest_mismatch}} =
             Persona.from_content(changed_manifest, File.read!(persona_path()))
  end

  defp persona_path do
    :openagents
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("sarah/persona/sarah.v1.md")
  end
end
