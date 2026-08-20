defmodule OpenAgentsWeb.NetworkStatusLiveTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders publicly for an anonymous browser visitor", %{conn: conn} do
    conn = conn |> put_req_header("accept", "text/html")
    {:ok, view, html} = live(conn, ~p"/status")

    assert html =~ "Network status"
    assert html =~ "BEAM nodes"
    assert html =~ "node 1"
    assert has_element?(view, ".status-metric__label", "computers connected")
    # Content-free: the serving node's internal name never reaches the page.
    refute html =~ to_string(node())
  end

  test "legacy JSON pollers of /status keep the old health payload", %{conn: conn} do
    # No Accept header (probe-style) → legacy JSON.
    response = conn |> get(~p"/status") |> json_response(200)
    assert %{"status" => "ok", "revision" => _revision} = response

    # Explicit JSON ask → legacy JSON.
    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/status")
      |> json_response(200)

    assert response["status"] == "ok"

    # ?format=json overrides even a browser Accept header.
    response =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> get(~p"/status?format=json")
      |> json_response(200)

    assert response["status"] == "ok"
  end

  test "GET /api/status returns the full projection as a superset of the legacy payload",
       %{conn: conn} do
    response = conn |> get(~p"/api/status") |> json_response(200)

    assert response["schema"] == "openagents.network_status.v1"
    assert response["status"] in ["ok", "degraded"]
    assert is_binary(response["revision"])
    assert is_list(response["nodes"])
    assert is_map(response["cluster"])
  end

  test "GET /healthz is unchanged", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/healthz") |> json_response(200)
  end

  alias OpenAgents.Forge.{DeployReceipt, Target}
  alias OpenAgents.Repo

  defp seed_target(status, opts \\ []) do
    %Target{}
    |> Target.changeset(%{
      repo: "openagents.com",
      sha: Keyword.get(opts, :sha, String.duplicate("c", 40)),
      promoted_by: Keyword.get(opts, :promoted_by, "operator:31337"),
      status: status
    })
    |> Repo.insert!()
  end

  describe "forge rollout visualization (#126)" do
    setup %{conn: conn} do
      # The projection is briefly cached; a stale cache from a neighboring
      # test would hide this test's seeded rows.
      :persistent_term.erase({OpenAgents.NetworkStatus, :cache})
      # /status only serves the LiveView to browser requests (#125).
      %{conn: put_req_header(conn, "accept", "text/html")}
    end

    test "renders the empty state before any deploy", %{conn: conn} do
      # Deterministic emptiness despite cross-test forge-row leakage: an
      # unused repo name for this test only.
      previous = Application.get_env(:openagents, :forge_repos)
      Application.put_env(:openagents, :forge_repos, ["nothing-here-yet"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:openagents, :forge_repos, previous),
          else: Application.delete_env(:openagents, :forge_repos)
      end)

      {:ok, _view, html} = live(conn, ~p"/status")

      assert html =~ "Rapid deploys"
      assert html =~ "No deploys yet"
    end

    test "renders the pipeline position for an advancing target", %{conn: conn} do
      seed_target("building")
      {:ok, _view, html} = live(conn, ~p"/status")

      assert html =~ ~r/status-pipeline__step--done[^>]*>\s*promoted/
      assert html =~ ~r/status-pipeline__step--active[^>]*>\s*building/
      # Later steps are pending — no marker class.
      refute html =~ ~r/status-pipeline__step--active[^>]*>\s*deploying/
    end

    test "renders a terminal non-live state as a first-class badge", %{conn: conn} do
      seed_target("needs_rolling_replace")
      {:ok, _view, html} = live(conn, ~p"/status")

      assert html =~ "needs_rolling_replace"
    end

    test "forge PubSub events land as event lines and refresh the page", %{conn: conn} do
      target = seed_target("promoted")
      {:ok, view, _html} = live(conn, ~p"/status")

      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        "forge:target",
        {:forge_target_status,
         %{repo: "openagents.com", sha: target.sha, target_id: target.id, status: "building"}}
      )

      html = render(view)
      assert html =~ "#{String.duplicate("c", 12)} → building"

      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        "forge:deploys",
        {:forge_deploy, %{repo: "openagents.com", sha: target.sha, result: "live"}}
      )

      assert render(view) =~ "hot deploy #{String.duplicate("c", 12)}: live"
    end

    test "the page is content-free: no operator identity, no module names", %{conn: conn} do
      target = seed_target("live", promoted_by: "operator:55554444")

      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "openagents.com",
        sha: target.sha,
        target_id: target.id,
        modules: ["Elixir.OpenAgents.HiddenModuleName"],
        result: "live",
        push_to_live_ms: 13_242
      })
      |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/status")

      assert html =~ "promoted by operator"
      assert html =~ "13.2s"
      refute html =~ "55554444"
      refute html =~ "HiddenModuleName"
      # Full sha never appears — only the short form.
      refute html =~ String.duplicate("c", 40)
    end
  end
end
