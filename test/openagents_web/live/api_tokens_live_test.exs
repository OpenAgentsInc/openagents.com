defmodule OpenAgentsWeb.ApiTokensLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenAgents.{ApiTokens, Repo}

  test "owner creates a one-time credential and revokes it", %{conn: conn} do
    user = github_user("api-token-live")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/settings/api-tokens")

    assert has_element?(view, "#api-token-form")
    assert has_element?(view, "#api-tokens-empty")

    view
    |> form("#api-token-form", %{
      "api_token" => %{"name" => "Local release", "lifetime_days" => "7"}
    })
    |> render_submit()

    assert has_element?(view, "#issued-api-token")
    assert [token] = ApiTokens.list(user)
    assert has_element?(view, "#revoke-api-token-#{token.id}")

    view |> element("#revoke-api-token-#{token.id}") |> render_click()

    refute has_element?(view, "#revoke-api-token-#{token.id}")
    assert Repo.reload!(token).revoked_at
  end

  test "anonymous browser is redirected without revealing the settings surface", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/api-tokens")
  end
end
