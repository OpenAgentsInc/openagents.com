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

    # The two scopes signing in already grants arrive ticked, so the common
    # case stays one click.
    assert has_element?(
             view,
             ~s(input[type="checkbox"][name="api_token[scope_chat:account]"][checked])
           )

    assert has_element?(
             view,
             ~s(input[type="checkbox"][name="api_token[scope_forge:write]"][checked])
           )

    refute has_element?(
             view,
             ~s(input[type="checkbox"][name="api_token[scope_box:control]"][checked])
           )

    view
    |> form("#api-token-form", %{
      "api_token" => %{
        "name" => "Local release",
        "lifetime_days" => "7",
        "scope_chat:account" => "true",
        "scope_forge:write" => "true"
      }
    })
    |> render_submit()

    assert has_element?(view, "#issued-api-token")
    assert [token] = ApiTokens.list(user)
    assert Enum.sort(token.scopes) == ["chat:account", "forge:write"]
    assert has_element?(view, "#revoke-api-token-#{token.id}")

    view |> element("#revoke-api-token-#{token.id}") |> render_click()

    refute has_element?(view, "#revoke-api-token-#{token.id}")
    assert Repo.reload!(token).revoked_at
  end

  test "the reader chooses the scopes, and gets exactly what was ticked", %{conn: conn} do
    user = github_user("api-token-scopes")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/settings/api-tokens")

    # The gap this closes: the form issued `chat:account` and `forge:write`
    # whatever the reader wanted, so a token for the box fleet could not be
    # made here at all and had to be minted on a node.
    view
    |> form("#api-token-form", %{
      "api_token" => %{
        "name" => "Box fleet",
        "lifetime_days" => "7",
        "scope_box:control" => "true",
        "scope_chat:account" => "true",
        "scope_forge:write" => "false",
        "scope_deployments:write" => "false",
        "scope_computer:control" => "false"
      }
    })
    |> render_submit()

    assert [token] = ApiTokens.list(user)
    assert Enum.sort(token.scopes) == ["box:control", "chat:account"]
    refute "forge:write" in token.scopes
  end

  test "a privileged scope is not offered, and a forged one is not honored", %{conn: conn} do
    user = github_user("api-token-privileged")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, html} = live(conn, ~p"/settings/api-tokens")

    refute html =~ "deployments:promote"

    # A parameter naming a scope the form never offered is read back against
    # the selectable list, so it cannot become a scope on the token. It is
    # submitted as an extra parameter because the form carries no such input —
    # which is the first half of the claim.
    view
    |> form("#api-token-form", %{
      "api_token" => %{
        "name" => "Forged",
        "lifetime_days" => "7",
        "scope_chat:account" => "true",
        "scope_forge:write" => "false",
        "scope_deployments:write" => "false",
        "scope_box:control" => "false",
        "scope_computer:control" => "false"
      }
    })
    |> render_submit(%{"api_token" => %{"scope_deployments:promote" => "true"}})

    assert [token] = ApiTokens.list(user)
    assert token.scopes == ["chat:account"]
  end

  test "a credential with no scope is refused rather than issued empty", %{conn: conn} do
    user = github_user("api-token-no-scope")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/settings/api-tokens")

    html =
      view
      |> form("#api-token-form", %{
        "api_token" => %{
          "name" => "Nothing",
          "lifetime_days" => "7",
          "scope_chat:account" => "false",
          "scope_forge:write" => "false",
          "scope_deployments:write" => "false",
          "scope_box:control" => "false",
          "scope_computer:control" => "false"
        }
      })
      |> render_submit()

    assert html =~ "at least one scope"
    assert ApiTokens.list(user) == []
  end

  test "anonymous browser is redirected without revealing the settings surface", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/api-tokens")
  end
end
