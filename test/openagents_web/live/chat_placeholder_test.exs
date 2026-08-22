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

    assert has_element?(view, "#chat-placeholder-transcript")
    assert has_element?(view, "#chat-placeholder-empty")
    assert has_element?(view, ~s(a[href="/sarah"]))
    assert has_element?(view, ~s(#chat-placeholder-form[data-submit-on-enter="true"]))
    assert has_element?(view, ~s(#chat-placeholder-form[data-clear-event="chat-preview:clear"]))
    assert has_element?(view, ~s(#chat_message[phx-mounted]))
    assert has_element?(view, ~s(#chat_reasoning[name="chat[reasoning]"]))
    assert has_element?(view, "#chat-placeholder-submit")
  end

  test "the composer shows a safe inline error when OpenRouter is not configured", %{conn: conn} do
    conn = log_in_admin_user(conn, "placeholder-composer-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#chat-placeholder-form", %{"chat" => %{"message" => "Draft the release notes."}})
    |> render_submit()

    assert has_element?(
             view,
             ~s([data-message-role="user"]),
             "Draft the release notes."
           )

    assert has_element?(view, ~s([role="status"]), "OpenRouter is not configured")
  end

  test "a non-operator on a live socket is still turned away by the mount hook", %{conn: conn} do
    # The plug gate runs on the initial document request; this drives the
    # LiveView mount directly so the on_mount hook is what answers.
    conn = log_in_chatting_user(conn, "socket-not-an-operator")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat")
  end
end
