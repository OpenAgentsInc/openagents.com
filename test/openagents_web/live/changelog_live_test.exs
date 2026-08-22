defmodule OpenAgentsWeb.ChangelogLiveTest do
  @moduledoc """
  The public changelog page and its API twin (#138, TRANSPARENCY-001):
  opens without a session, shows the human layer with the receipt detail
  expandable underneath, keeps the anonymous command bar free of account
  controls, stays content-free of node internals, and serves the same
  timeline as schema-versioned JSON at /api/changelog — 404 for a dark
  repo.
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

  test "renders the entry's summary and category for a visitor with no session", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ "Changelog"
    assert html =~ "Moved the mic button test entry"
    assert html =~ ~s(id="changelog-filter-ui")
  end

  test "the detail expansion carries the sha and a link to the commit page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    assert html =~ "abcdef1"
    assert html =~ "/OpenAgentsInc/openagents.com/commit/abcdef1"
  end

  test "carries the shared command bar without account controls for a visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    # The shell supplies the one command bar; the page no longer builds a second.
    refute html =~ ~s(class="command-bar")
    refute html =~ ~s(id="account-bar-trigger")
    refute html =~ ~s(id="return-to-conversation")
  end

  test "carries the shell sidebar when logged in", %{conn: conn} do
    conn = log_in_chatting_user(conn, "changelog-header-browser")

    {:ok, _view, html} = live(conn, ~p"/changelog")

    # Chat is a sidebar row, so the page carries no chip back to it.
    refute html =~ ~s(id="return-to-conversation")
    assert html =~ ~s(href="/sarah")
  end

  test "publishes no node internals", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changelog")

    refute html =~ to_string(node())
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
