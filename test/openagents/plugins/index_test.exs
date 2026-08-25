defmodule OpenAgents.Plugins.IndexTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Plugins.Index

  @fixture_path "test/fixtures/plugin_manifest.json"

  defp shipping_manifest do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  test "lists only validated manifests" do
    entries = [
      %{
        repository: "OpenAgentsInc/git-lost-work",
        release: "main",
        raw_manifest: shipping_manifest()
      },
      %{repository: "OpenAgentsInc/bad", release: "main", raw_manifest: %{"name" => "bad"}}
    ]

    [validated] = Index.list(source: entries)
    assert validated.repository == "OpenAgentsInc/git-lost-work"
    assert validated.release == "main"
    assert validated.manifest["name"] == "git_lost_work"
  end

  test "returns an empty list when every manifest is invalid" do
    entries = [
      %{repository: "OpenAgentsInc/bad", release: "main", raw_manifest: %{}},
      %{repository: "OpenAgentsInc/bad2", release: "main", raw_manifest: "not a map"}
    ]

    assert Index.list(source: entries) == []
  end

  test "skips malformed source rows without crashing" do
    entries = [
      %{
        repository: "OpenAgentsInc/git-lost-work",
        release: "main",
        raw_manifest: shipping_manifest()
      },
      %{repository: "OpenAgentsInc/bad", release: "main"},
      %{release: "main", raw_manifest: %{}},
      "not a map"
    ]

    [validated] = Index.list(source: entries)
    assert validated.repository == "OpenAgentsInc/git-lost-work"
    assert validated.release == "main"
    assert validated.manifest["name"] == "git_lost_work"
  end

  test "finds a plugin by exact name" do
    entries = [
      %{
        repository: "OpenAgentsInc/git-lost-work",
        release: "main",
        raw_manifest: shipping_manifest()
      }
    ]

    assert {:ok, %Index.Entry{}} = Index.get("git_lost_work", source: entries)
    assert {:error, :not_found} = Index.get("unknown", source: entries)
  end

  test "renders an entry as a JSON map" do
    entry = %Index.Entry{
      repository: "OpenAgentsInc/git-lost-work",
      release: "main",
      manifest: shipping_manifest()
    }

    map = Index.to_map(entry)
    assert map["repository"] == "OpenAgentsInc/git-lost-work"
    assert map["release"] == "main"
    assert map["manifest"]["name"] == "git_lost_work"
  end
end
