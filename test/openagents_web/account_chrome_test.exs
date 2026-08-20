defmodule OpenAgentsWeb.AccountChromeTest do
  @moduledoc """
  The shell's identity and connection chrome.

  Both carry claims about state, so both are asserted rather than eyeballed:
  the account menu must not show an empty line where a person's name goes, and
  the connection marker must actually be driven by the socket.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.Accounts

  describe "account menu identity" do
    test "leads with the person's name and keeps the handle as the qualifier", %{conn: conn} do
      conn = log_in_github_user(conn, "named-account")
      user = github_user("named-account")

      # Logging in refreshes the display fields from GitHub, so the name is set
      # the way a real login sets it: through the upsert, after authentication.
      {:ok, user} =
        Accounts.upsert_github_user(%{
          github_id: user.github_id,
          github_login: user.github_login,
          github_name: "Ada Lovelace",
          github_avatar_url: user.github_avatar_url
        })

      assert user.github_name == "Ada Lovelace"
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "Ada Lovelace"
      assert html =~ "@#{user.github_login}"
      refute html =~ "GITHUB ACCOUNT"
    end

    test "falls back to the handle when GitHub has no name for the account", %{conn: conn} do
      user = github_user("nameless-account")
      assert user.github_name == nil

      conn = log_in_github_user(conn, "nameless-account")
      {:ok, _view, html} = live(conn, ~p"/chat")

      # The handle becomes the display name, and is not then repeated beneath
      # itself as a qualifier.
      assert html =~ "@#{user.github_login}"
      refute html =~ "<strong></strong>"

      identity =
        Regex.run(~r|menu__identity.{0,900}|s, html)
        |> List.first()

      assert identity =~ "@#{user.github_login}"
      refute identity =~ "<small"
    end
  end

  describe "connection chrome" do
    test "the conversation states no connection status at all", %{conn: conn} do
      conn = log_in_github_user(conn, "connection-user")
      {:ok, view, html} = live(conn, ~p"/chat")

      # Removed at the owner's direction. A bar that reads CONNECTED whenever
      # the page is working spends permanent space to say nothing: the only
      # state worth reporting is the one where it is not, and LiveView already
      # shows that through the disconnect overlay.
      refute has_element?(view, ".chat-status")
      refute html =~ "CONNECTED"
      refute html =~ "chat-connection"
    end
  end

  describe "composer chrome" do
    test "drops the keyboard hint line", %{conn: conn} do
      conn = log_in_github_user(conn, "composer-hint-user")
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "FOR A NEW LINE"
      refute html =~ "TO SEND"
      assert html =~ ~s(id="send-message")
    end
  end
end
