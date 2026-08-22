defmodule OpenAgentsWeb.AgentSurfacesTest do
  @moduledoc """
  The agent's sidebar section is grandfathered, not launched.

  An account that has already talked to her keeps her surfaces, and an operator
  always has them. A new account does not, and will not until it writes to her.

  These are worth holding because the failure is silent in the direction that
  matters: if the check goes permissive -- and the obvious implementation does,
  since every conversation is created with a greeting message already in it --
  the section simply appears for everybody and nothing anywhere complains.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  @section "#sidebar #sidebar-section-sarah"

  describe "who sees her" do
    test "a new account does not", %{conn: conn} do
      conn = log_in_github_user(conn, "brand-new-account")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      refute has_element?(view, @section)
      refute has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/sarah"]))
      refute has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/memory"]))
      refute has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/computers"]))
      # The operator-only chat surface is hidden from a non-operator too.
      refute has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/chat"]))
    end

    test "an account that has written to her does", %{conn: conn} do
      conn = log_in_chatting_user(conn, "already-talked")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, @section)
      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/sarah"]))
      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/memory"]))
      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/computers"]))
      refute has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/chat"]))
    end

    test "an operator does, without having written", %{conn: conn} do
      conn = log_in_admin_user(conn, "operator-who-never-chatted")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, @section)
      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/sarah"]))
      # The operator's own chat surface sits in the main nav, above
      # Repositories.
      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/chat"]))

      html = render(view)
      assert {chat_at, _len} = :binary.match(html, ~s(href="/chat"))

      assert {repositories_at, _len} =
               :binary.match(html, ~s(href="/repositories"))

      assert chat_at < repositories_at
    end

    test "the rest of the sidebar is unaffected either way", %{conn: conn} do
      # The gate hides one section, not the application. A new account still
      # gets the shared destinations and the footer.
      conn = log_in_github_user(conn, "new-account-still-has-a-sidebar")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/"]))
      assert has_element?(view, ~s(#sidebar .sidebar-footer a[href="/docs"]))
      assert has_element?(view, "#account-bar-trigger")
    end
  end

  describe "earning her" do
    test "the first message reveals the section without a reload", %{conn: conn} do
      conn = log_in_github_user(conn, "first-message-account")
      {:ok, view, _html} = live(conn, ~p"/sarah")

      refute has_element?(view, @section)

      view
      |> form("#message-form", chat: %{message: "Hello."})
      |> render_submit()

      assert has_element?(view, @section)
    end
  end
end
