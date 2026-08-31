defmodule OpenAgentsWeb.CoderTokenControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens
  alias OpenAgents.CoderToken

  test "mints an Ed25519-signed Coder-audience token with every claim", %{conn: conn} do
    user = github_user("coder-token", "token-user")

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Coder", scopes: ["chat:account"]})

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(~p"/api/v1/coder/token")

    assert %{
             "token" => token,
             "audience" => "coder",
             "expires_in" => expires_in
           } = json_response(response, 200)

    assert expires_in == CoderToken.ttl_seconds()
    assert expires_in <= 900
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert [header, payload, signature] = String.split(token, ".")

    assert %{"alg" => "EdDSA", "typ" => "JWT"} =
             header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert claims["iss"] == "openagents.com"
    assert claims["sub"] == to_string(user.id)
    assert claims["aud"] == "coder"
    assert claims["scope"] == "responses"
    assert claims["login"] == user.github_login
    assert claims["github_id"] == user.github_id
    assert is_integer(claims["iat"])
    assert claims["exp"] == claims["iat"] + expires_in
    assert {:ok, _uuid} = Ecto.UUID.cast(claims["jti"])

    # The signature verifies against the public half of the configured seed,
    # which is exactly the check Coder runs locally.
    seed =
      :openagents
      |> Application.get_env(:coder_token_signing_key)
      |> Base.decode64!()

    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    raw_signature = Base.url_decode64!(signature, padding: false)

    assert :crypto.verify(
             :eddsa,
             :none,
             header <> "." <> payload,
             raw_signature,
             [public_key, :ed25519]
           )
  end

  test "requires the chat account scope", %{conn: conn} do
    assert %{"code" => "unauthenticated"} =
             conn
             |> post(~p"/api/v1/coder/token")
             |> json_response(401)
  end

  test "answers 503 when no signing key is configured", %{conn: conn} do
    configured = Application.get_env(:openagents, :coder_token_signing_key)
    Application.put_env(:openagents, :coder_token_signing_key, nil)
    on_exit(fn -> Application.put_env(:openagents, :coder_token_signing_key, configured) end)

    user = github_user("coder-token-keyless", "keyless-user")

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Coder", scopes: ["chat:account"]})

    assert %{"code" => "coder_token_unavailable"} =
             conn
             |> put_req_header("authorization", "Bearer " <> plaintext)
             |> post(~p"/api/v1/coder/token")
             |> json_response(503)
  end
end
