defmodule OpenAgentsWeb.CoderGrantControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens
  alias OpenAgents.CoderGrant
  alias OpenAgents.Repo

  defp bearer(conn, key, login) do
    user = github_user(key, login)
    {:ok, _token, plaintext} = ApiTokens.create(user, %{name: "Coder", scopes: ["chat:account"]})
    {user, put_req_header(conn, "authorization", "Bearer " <> plaintext)}
  end

  test "mints an Ed25519-signed spending grant with every claim", %{conn: conn} do
    {user, conn} = bearer(conn, "coder-grant", "grant-user")

    response = post(conn, ~p"/api/v1/coder/grant")

    assert %{
             "grant" => grant,
             "grant_id" => grant_id,
             "audience" => "coder-grant",
             "amount_microusd" => amount,
             "expires_in" => expires_in
           } = json_response(response, 200)

    assert expires_in == CoderGrant.ttl_seconds()
    assert expires_in <= 3_600
    assert amount == 5_000_000
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert [header, payload, signature] = String.split(grant, ".")

    assert %{"alg" => "EdDSA", "typ" => "JWT"} =
             header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert claims["iss"] == "openagents.com"
    assert claims["sub"] == to_string(user.id)
    assert claims["aud"] == "coder-grant"
    assert claims["amount_microusd"] == amount
    assert is_integer(claims["iat"])
    assert claims["exp"] == claims["iat"] + expires_in
    assert claims["jti"] == grant_id
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
             |> post(~p"/api/v1/coder/grant")
             |> json_response(401)
  end

  test "answers 503 when no signing key is configured", %{conn: conn} do
    configured = Application.get_env(:openagents, :coder_token_signing_key)
    Application.put_env(:openagents, :coder_token_signing_key, nil)
    on_exit(fn -> Application.put_env(:openagents, :coder_token_signing_key, configured) end)

    {_user, conn} = bearer(conn, "coder-grant-keyless", "grant-keyless")

    assert %{"code" => "coder_grant_unavailable"} =
             conn
             |> post(~p"/api/v1/coder/grant")
             |> json_response(503)
  end

  test "never grants more than the config ceiling", %{conn: conn} do
    {_user, conn} = bearer(conn, "coder-grant-greedy", "grant-greedy")

    assert %{"amount_microusd" => amount, "grant" => grant} =
             conn
             |> post(~p"/api/v1/coder/grant", %{"amount_microusd" => 1_000_000_000})
             |> json_response(200)

    assert amount == CoderGrant.ceiling_microusd()

    [_header, payload, _signature] = String.split(grant, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["amount_microusd"] == amount
  end

  test "grants no more than the account's remaining credit", %{conn: conn} do
    {user, conn} = bearer(conn, "coder-grant-thin", "grant-thin")

    {:ok, _user} =
      user
      |> Ecto.Changeset.change(credit_allowance_microusd: 250_000)
      |> Repo.update()

    assert %{"amount_microusd" => 250_000} =
             conn
             |> post(~p"/api/v1/coder/grant")
             |> json_response(200)
  end

  test "refuses an account with no credit left", %{conn: conn} do
    {user, conn} = bearer(conn, "coder-grant-broke", "grant-broke")

    {:ok, _user} =
      user
      |> Ecto.Changeset.change(credit_allowance_microusd: 0)
      |> Repo.update()

    assert %{"code" => "insufficient_credit"} =
             conn
             |> post(~p"/api/v1/coder/grant")
             |> json_response(402)
  end

  test "refuses a malformed amount", %{conn: conn} do
    {_user, conn} = bearer(conn, "coder-grant-mangled", "grant-mangled")

    assert %{"code" => "invalid_amount"} =
             conn
             |> post(~p"/api/v1/coder/grant", %{"amount_microusd" => "five dollars"})
             |> json_response(422)
  end
end
