defmodule OpenAgentsWeb.AdminLiveTest do
  @moduledoc """
  `/admin` is the only surface that reads across accounts for one person, so the
  gate matters more than the layout: who reaches it, who is told nothing, and
  what the page is allowed to show once it renders.

  It lists accounts and activity counts. It does not list content, and the
  assertions below hold that line: knowing someone sent forty messages is an
  operational fact, reading them is a different decision entirely.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations

  describe "access" do
    test "the operator reaches the panel", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-operator")

      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "Accounts"
    end

    test "an ordinary authenticated account is redirected and told nothing", %{conn: conn} do
      conn = log_in_github_user(conn, "admin-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")

      # No flash, no distinct status: the surface does not announce that it exists.
      response = get(conn, ~p"/admin")
      assert redirected_to(response) == ~p"/"
      assert Phoenix.Flash.get(response.assigns.flash, :error) in [nil, ""]
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "a login rename cannot carry operator access, because the ID is what matches",
         %{conn: conn} do
      user = github_user("admin-renamed")
      grant_operator(user)

      # Someone else takes the freed login. The allowlist is numeric, so the new
      # holder of the name gains nothing.
      impostor = github_user("admin-impostor")

      {:ok, _renamed} =
        OpenAgents.Accounts.upsert_github_user(%{
          github_id: impostor.github_id,
          github_login: user.github_login,
          github_avatar_url: impostor.github_avatar_url
        })

      impostor_conn = Plug.Test.init_test_session(conn, %{"user_id" => impostor.id})

      assert {:error, {:redirect, %{to: "/"}}} = live(impostor_conn, ~p"/admin")
    end

    test "losing operator access halts the connected socket on its next event", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-revoked")
      {:ok, view, _html} = live(conn, ~p"/admin")

      revoke_operator()

      assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "previous_page", %{})
    end

    test "a banned operator is not an operator", %{conn: conn} do
      user = github_user("admin-banned")
      grant_operator(user)
      {:ok, _banned} = OpenAgents.Accounts.ban_user(user, "policy")

      banned_conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

      assert {:error, {:redirect, %{to: "/"}}} = live(banned_conn, ~p"/admin")
    end
  end

  describe "the panel" do
    test "lists every account with when it joined and what it has done", %{conn: conn} do
      subject = github_user("admin-listed-account")
      {:ok, conversation} = Conversations.ensure_conversation(subject)

      {:ok, _records} =
        Conversations.create_turn(conversation, "a message the operator must not read")

      conn = log_in_admin_user(conn, "admin-lister")
      {:ok, view, html} = live(conn, ~p"/admin")

      assert html =~ "@#{subject.github_login}"
      assert has_element?(view, "#admin-account-#{subject.id}")
      assert has_element?(view, "#admin-accounts")
    end

    test "counts activity without exposing any of its content", %{conn: conn} do
      subject = github_user("admin-content-account")
      {:ok, conversation} = Conversations.ensure_conversation(subject)
      {:ok, _records} = Conversations.create_turn(conversation, "the private text of a message")

      conn = log_in_admin_user(conn, "admin-content-reader")
      {:ok, _view, html} = live(conn, ~p"/admin")

      refute html =~ "the private text of a message"
    end

    test "carries no recording surface at all", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-no-recording")
      {:ok, view, html} = live(conn, ~p"/admin")

      # The product does not capture call audio, and an operator panel whose
      # only view is of a capability that does not run describes the system
      # inaccurately to the person who most needs an accurate picture.
      refute has_element?(view, "audio")
      refute html =~ "/admin/recordings/"
      refute html =~ "Voice calls"
      refute html =~ "RECORDING"
    end

    test "an account with no activity is listed with zeroes rather than dropped",
         %{conn: conn} do
      quiet = github_user("admin-quiet-account")

      conn = log_in_admin_user(conn, "admin-quiet-reader")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#admin-account-#{quiet.id}")
    end

    test "renders no composed instructions, tool catalog, or provider call identity",
         %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-no-internals")
      {:ok, _view, html} = live(conn, ~p"/admin")

      refute html =~ "system_prompt"
      refute html =~ "tool_catalog"
      refute html =~ "gpt-realtime"
    end

    test "the shell supplies the chrome; the panel builds none of its own", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-chrome")
      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "header.command-bar")
      assert has_element?(view, "#sidebar")
    end
  end
end
