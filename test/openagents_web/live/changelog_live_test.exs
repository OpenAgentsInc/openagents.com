defmodule OpenAgentsWeb.ChangelogLiveTest do
  @moduledoc """
  The documentation changelog and the retained changelog API.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Changelog

  setup do
    :persistent_term.erase({OpenAgents.Changelog, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.Changelog, :cache}) end)

    {:ok, entry} =
      Changelog.record(%{
        repo: "openagents.com",
        sha: "abcdef1",
        summary: "Moved the mic button test entry",
        category: "ui",
        source: "operator",
        entry_at: DateTime.utc_now(),
        visibility: "l2"
      })

    %{entry: entry}
  end

  test "GET /changelog redirects to the documentation changelog", %{conn: conn} do
    conn = get(conn, ~p"/changelog")

    assert redirected_to(conn, 302) == ~p"/docs/changelog"
  end

  test "the documentation changelog presents Coder v0.1.1 and v0.1.0", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/docs/changelog")

    assert html =~ "Coder v0.1.1"
    assert html =~ "Released August 28, 2026."
    assert html =~ "See the session as it runs"
    assert html =~ "Message other sessions"
    assert html =~ "Route Flash work"
    assert html =~ "simple questions to Gemini 3.7 Flash"

    assert html =~ "Coder v0.1.0"
    assert html =~ "Released August 26, 2026."
    assert html =~ "Choose how inference runs"
    assert html =~ "Delegate work"
  end

  test "GET /api/changelog returns the schema-versioned projection", %{conn: conn} do
    conn = get(conn, ~p"/api/changelog")
    payload = json_response(conn, 200)

    assert payload["schema"] == "openagents.changelog.v1"
    assert payload["repo"] == "openagents.com"

    assert Enum.any?(
             payload["entries"],
             &(&1["summary"] == "Moved the mic button test entry")
           )
  end

  test "GET /api/changelog?repo=demo is 404 — the repo is dark", %{conn: conn} do
    conn = get(conn, ~p"/api/changelog?repo=demo")

    assert json_response(conn, 404) == %{"error" => "not found"}
  end
end
