defmodule OpenAgentsWeb.ChatPlaceholderTest do
  @moduledoc """
  `/chat` is the operator-only placeholder for the upcoming chat surface.

  The gate is worth its own file because it fails in two quiet directions: a
  missing plug lets a signed-in non-operator read the page, and a missing
  on_mount hook lets a LiveView event run on a socket that never passed the
  gate.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  test "an anonymous request is sent home", %{conn: conn} do
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "a signed-in non-operator is sent home", %{conn: conn} do
    conn = log_in_github_user(conn, "not-an-operator")
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "an operator gets the placeholder", %{conn: conn} do
    conn = log_in_admin_user(conn, "placeholder-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-placeholder-empty")
    assert has_element?(view, ~s(a[href="/sarah"]))
  end

  test "a non-operator on a live socket is still turned away by the mount hook", %{conn: conn} do
    # The plug gate runs on the initial document request; this drives the
    # LiveView mount directly so the on_mount hook is what answers.
    conn = log_in_chatting_user(conn, "socket-not-an-operator")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat")
  end
end
