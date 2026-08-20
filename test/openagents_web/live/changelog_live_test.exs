defmodule OpenAgentsWeb.ChangelogLiveTest do
  @moduledoc """
  The public changelog page and its API twin (#138, TRANSPARENCY-001):
  opens without a session, shows the human layer with the receipt detail
  expandable underneath, keeps the anonymous command bar free of account
  controls, stays content-free of node internals, and serves the same
  timeline as schema-versioned JSON at /api/changelog — 404 for a dark
  repo.
  """

  use OpenAgentsWeb.SarahConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Changelog

  setup do
    :persistent_term.erase({OpenAgents.Changelog, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.Changelog, :cache}) end)

    {:ok, entry} =
      Changelog.record(%{
        repo: "sarah",
        sha: "abcdef1",
        summary: "Moved the mic button test entry",
        category: "ui",
        source: "operator",
        entry_at: DateTime.utc_now(),
        visibility: "l2"
      })

    %{entry: entry}
  end

  test "renders the entry's summary and category for a visitor with no session", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ "Changelog"
    assert html =~ "Moved the mic button test entry"
    assert html =~ ~s(id="changelog-filter-ui")
  end

  test "the detail expansion carries the sha and a link to the commit page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ "abcdef1"
    assert html =~ "/OpenAgentsInc/sarah/commit/abcdef1"
  end

  test "carries the shared command bar without account controls for a visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ ~s(class="command-bar")
    refute html =~ ~s(id="account-menu-trigger")
    refute html =~ ~s(id="return-to-conversation")
  end

  test "offers a way back to the conversation when logged in", %{conn: conn} do
    conn = log_in_github_user(conn, "changelog-header-browser")

    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ ~s(id="return-to-conversation")
    assert html =~ "RETURN TO CONVERSATION"
  end

  test "publishes no node internals", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    refute html =~ to_string(node())
  end

  test "GET /api/changelog returns the schema-versioned projection", %{conn: conn} do
    conn = get(conn, ~p"/api/changelog")
    payload = json_response(conn, 200)

    assert payload["schema"] == "sarah.changelog.v1"
    assert payload["repo"] == "sarah"

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
