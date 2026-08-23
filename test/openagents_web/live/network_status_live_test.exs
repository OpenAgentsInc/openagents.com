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
    assert has_element?(view, "#status-scvs")
    assert has_element?(view, "#status-no-scvs")
    # Content-free: the serving node's internal name never reaches the page.
    refute html =~ to_string(node())
  end

  test "renders bounded live SCV activity without private event content", %{conn: conn} do
    run_id = Ecto.UUID.generate()

    OpenAgents.SCV.Activity.observe(%{
      schema: "openagents.scv.event.v1",
      run_id: run_id,
      type: "opencode_event",
      event_type: "tool_use",
      tool: "grep",
      objective: "private parity objective",
      repository: "/workspace/private-repository",
      output: "private tool output"
    })

    _projection = OpenAgents.SCV.Activity.public_projection()

    on_exit(fn ->
      OpenAgents.SCV.Activity.observe(%{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "run_finished"
      })

      _projection = OpenAgents.SCV.Activity.public_projection()
    end)

    conn = put_req_header(conn, "accept", "text/html")
    {:ok, view, html} = live(conn, ~p"/status")

    assert has_element?(view, "#public-scv-streams")
    assert html =~ "Searching repository context"
    refute html =~ run_id
    refute html =~ "private parity objective"
    refute html =~ "/workspace/private-repository"
    refute html =~ "private tool output"
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

  test "GET /health is the public readiness probe", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)
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

      {:ok, view, html} = live(conn, ~p"/status")

      assert html =~ "Rapid deploys"
      assert has_element?(view, "#status-forge-state")
      assert html =~ "No deploys yet"
      assert has_element?(view, "#status-forge-no-deploys")
      assert html =~ "No deployment receipts yet"
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

    test "renders deployment history with lane, completion time, and duration", %{conn: conn} do
      target = seed_target("live")
      now = DateTime.utc_now()

      receipts = [
        # Oldest: classification only.
        %{result: "needs_rolling_replace"},
        %{
          result: "live",
          deployment_type: "direct_load",
          started_at: DateTime.add(now, -13_242, :millisecond),
          completed_at: now
        },
        # Newest: a settled relup.
        %{
          result: "live",
          deployment_type: "relup",
          started_at: DateTime.add(now, -2_500, :millisecond),
          completed_at: now
        }
      ]

      for receipt <- receipts do
        %DeployReceipt{}
        |> DeployReceipt.changeset(
          Map.merge(%{repo: "openagents.com", sha: target.sha, target_id: target.id}, receipt)
        )
        |> Repo.insert!()

        # Distinct inserted_at ordering under usec timestamps.
        Process.sleep(2)
      end

      {:ok, view, html} = live(conn, ~p"/status")

      assert html =~ "Recent deployments"
      assert has_element?(view, "#status-forge-history li[data-deploy-type='direct_load']")
      assert has_element?(view, "#status-forge-history li[data-deploy-type='relup']")
      assert has_element?(view, "#status-forge-history li[data-deploy-type='none']")
      assert html =~ "direct load"
      assert html =~ "classification only"
      assert html =~ "took 13.2s"
      assert html =~ "took 2.5s"
      assert html =~ "completed #{Calendar.strftime(now, "%Y-%m-%d")}"

      # Newest first: the relup receipt renders before the direct load.
      {relup_at, _} = :binary.match(html, ~s(data-deploy-type="relup"))
      {direct_at, _} = :binary.match(html, ~s(data-deploy-type="direct_load"))
      assert relup_at < direct_at
    end

    test "the deployment list updates when Forge records a new receipt", %{conn: conn} do
      target = seed_target("live", sha: String.duplicate("d", 40))
      {:ok, view, html} = live(conn, ~p"/status")

      refute html =~ ~s(data-deploy-type="direct_load")

      %DeployReceipt{}
      |> DeployReceipt.changeset(%{
        repo: "openagents.com",
        sha: target.sha,
        target_id: target.id,
        result: "live",
        deployment_type: "direct_load"
      })
      |> Repo.insert!()

      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        "forge:deploys",
        {:forge_deploy, %{repo: "openagents.com", sha: target.sha, result: "live"}}
      )

      html = render(view)
      assert html =~ ~s(data-deploy-type="direct_load")
      assert html =~ "direct load"
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

      {:ok, view, html} = live(conn, ~p"/status")

      assert html =~ "promoted by operator"
      assert html =~ "13.2s"
      assert html =~ "deploy policy: direct hot load → relup → rolling replacement"
      assert has_element?(view, "#status-forge-policy[data-path-order='direct,relup,rolling']")
      refute html =~ "55554444"
      refute html =~ "HiddenModuleName"
      # Full sha never appears — only the short form.
      refute html =~ String.duplicate("c", 40)
    end
  end
end
