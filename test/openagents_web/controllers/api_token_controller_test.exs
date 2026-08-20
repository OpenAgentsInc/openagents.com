defmodule OpenAgentsWeb.ApiTokenControllerTest do
  use OpenAgentsWeb.ConnCase, async: true
  import Ecto.Query

  alias OpenAgents.{ApiTokens, Repo}

  test "a browser-authenticated owner issues a token once and can revoke it", %{conn: conn} do
    user = github_user("api-token-controller-owner")
    browser = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    issued =
      post(browser, ~p"/api/tokens", %{
        name: "local CLI",
        scopes: ["forge:write"],
        lifetime_days: 30
      })

    assert get_resp_header(issued, "cache-control") == ["no-store"]
    assert %{"token" => plaintext, "credential" => %{"id" => id}} = json_response(issued, 201)
    assert String.starts_with?(plaintext, "oa_pat_")
    assert {:ok, ^user, _token} = ApiTokens.authenticate(plaintext, "forge:write")

    listed = issued |> recycle() |> get(~p"/api/tokens")
    assert [%{"id" => ^id}] = json_response(listed, 200)["tokens"]
    refute inspect(json_response(listed, 200)) =~ plaintext

    revoked = listed |> recycle() |> delete(~p"/api/tokens/#{id}")
    assert json_response(revoked, 200)["credential"]["revoked_at"]
    assert {:error, :invalid_api_token} = ApiTokens.authenticate(plaintext, "forge:write")
  end

  test "forge mutations refuse missing, malformed, expired, and revoked credentials", %{
    conn: conn
  } do
    path = ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues"

    missing = conn |> delete_req_header("authorization") |> post(path, %{title: "denied"})
    assert json_response(missing, 401) == %{"error" => "invalid_api_token"}

    malformed =
      conn
      |> put_req_header("authorization", "Bearer not-a-token")
      |> post(path, %{title: "denied"})

    assert json_response(malformed, 401) == %{"error" => "invalid_api_token"}

    user = github_user("api-token-denial-owner")

    assert {:ok, token, plaintext} =
             ApiTokens.create(user, %{
               name: "denial cases",
               scopes: ["forge:write"],
               lifetime_days: 1
             })

    backdated = DateTime.add(DateTime.utc_now(), -2, :day)

    Repo.update_all(from(t in OpenAgents.ApiTokens.ApiToken, where: t.id == ^token.id),
      set: [inserted_at: backdated]
    )

    expired_token =
      Repo.get!(OpenAgents.ApiTokens.ApiToken, token.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    expired =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(path, %{title: "denied"})

    assert json_response(expired, 401) == %{"error" => "invalid_api_token"}

    fresh_token =
      expired_token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), 1, :day))
      |> Repo.update!()

    assert {:ok, _revoked} = ApiTokens.revoke(user, fresh_token.id)

    revoked =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(path, %{title: "denied"})

    assert json_response(revoked, 401) == %{"error" => "invalid_api_token"}
  end

  test "browser credential mutations remain CSRF protected" do
    user = github_user("api-token-csrf-owner")

    browser =
      build_conn()
      |> init_test_session(%{"user_id" => user.id})
      |> get(~p"/settings/api-tokens")

    assert is_binary(get_session(browser, "_csrf_token"))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      browser
      |> recycle()
      |> enable_csrf_protection()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-csrf-token", "invalid")
      |> post(~p"/api/tokens", %{
        name: "must not exist",
        scopes: ["forge:write"],
        lifetime_days: 1
      })
    end
  end

  defp enable_csrf_protection(conn) do
    %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
  end
end
