defmodule OpenAgentsWeb.PluginRegistryControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  @fixture_path "test/fixtures/plugin_manifest.json"

  defp shipping_manifest do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  setup do
    old = Application.get_env(:openagents, OpenAgents.Plugins.Index)

    entries = [
      %{
        repository: "OpenAgentsInc/git-lost-work",
        release: "main",
        raw_manifest: shipping_manifest()
      },
      %{repository: "OpenAgentsInc/bad", release: "main", raw_manifest: %{"name" => "bad"}}
    ]

    Application.put_env(:openagents, OpenAgents.Plugins.Index, source: entries)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:openagents, OpenAgents.Plugins.Index),
        else: Application.put_env(:openagents, OpenAgents.Plugins.Index, old)
    end)

    :ok
  end

  test "GET /api/v1/plugins lists validated plugins only", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/plugins")
    assert %{"plugins" => [plugin]} = json_response(conn, 200)
    assert plugin["repository"] == "OpenAgentsInc/git-lost-work"
    assert plugin["manifest"]["name"] == "git_lost_work"
  end

  test "GET /api/v1/plugins/:name returns the exact-name match", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/plugins/git_lost_work")
    assert %{"plugin" => plugin} = json_response(conn, 200)
    assert plugin["manifest"]["name"] == "git_lost_work"
  end

  test "GET /api/v1/plugins/:name returns 404 for an unknown plugin", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/plugins/unknown")
    assert_api_error(conn, 404, "not_found")
  end
end
