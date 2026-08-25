defmodule OpenAgents.Plugins.SearchTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Plugins.Index

  @fixture_path "test/fixtures/plugin_manifest.json"
  @weather_manifest %{
    "manifest_version" => 1,
    "name" => "weather_check",
    "version" => "0.1.0",
    "author" => "OpenAgents",
    "description" => "Check the local weather forecast and report current conditions.",
    "artifact" => %{
      "path" => "weather_check.wasm",
      "digest" => "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    },
    "abi" => %{
      "kind" => "packet-v0",
      "entry" => "handle_packet",
      "alloc" => "packet_alloc"
    },
    "interface" => %{
      "input" => %{"type" => "object"},
      "output" => %{"type" => "object"}
    },
    "capabilities" => %{
      "mounts" => [],
      "hosts" => [],
      "timeout_ms" => 1000,
      "memory_max_mib" => 64
    },
    "price_msats" => nil,
    "license" => "MIT"
  }

  setup do
    original = Application.get_env(:openagents, :plugin_discovery)
    :persistent_term.put({OpenAgents.Plugins.Embeddings, :vectors}, nil)

    on_exit(fn ->
      :persistent_term.put({OpenAgents.Plugins.Embeddings, :vectors}, nil)
      Application.put_env(:openagents, :plugin_discovery, original)
    end)

    :ok
  end

  defp git_manifest do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp git_entry,
    do: %{
      repository: "OpenAgentsInc/git-lost-work",
      release: "main",
      raw_manifest: git_manifest()
    }

  defp weather_entry,
    do: %{
      repository: "OpenAgentsInc/weather-check",
      release: "main",
      raw_manifest: @weather_manifest
    }

  describe "search/2" do
    test "ranks manifests by cosine when embeddings are enabled" do
      Application.put_env(:openagents, :plugin_discovery,
        embeddings_enabled: true,
        provider: OpenAgents.Plugins.EmbeddingsTestProvider,
        model_id: "test",
        model_version: "test",
        dimensions: 4,
        top_k: 2
      )

      {:ok, [first, second]} = Index.search("git history", source: [git_entry(), weather_entry()])

      assert first.manifest["name"] == "git_lost_work"
      assert first.score > 0.0
      assert second.manifest["name"] == "weather_check"
      assert second.score == 0.0
      assert first.score > second.score
    end

    test "returns the unranked candidate list when embeddings are disabled" do
      Application.put_env(:openagents, :plugin_discovery,
        embeddings_enabled: false,
        provider: OpenAgents.Plugins.EmbeddingsTestProvider,
        model_id: "test",
        model_version: "test",
        dimensions: 4,
        top_k: 1
      )

      {:ok, [first, second]} = Index.search("git history", source: [git_entry(), weather_entry()])

      assert first.manifest["name"] == "git_lost_work"
      assert is_nil(first.score)
      assert second.manifest["name"] == "weather_check"
      assert is_nil(second.score)
    end

    test "returns the unranked candidate list instead of raising when the provider errors" do
      Application.put_env(:openagents, :plugin_discovery,
        embeddings_enabled: true,
        provider: OpenAgents.Plugins.EmbeddingsErrorProvider,
        model_id: "test",
        model_version: "test",
        dimensions: 4,
        top_k: 1
      )

      {:ok, [first, second]} = Index.search("git history", source: [git_entry(), weather_entry()])

      assert first.manifest["name"] == "git_lost_work"
      assert is_nil(first.score)
      assert second.manifest["name"] == "weather_check"
      assert is_nil(second.score)
    end
  end
end
