defmodule OpenAgentsWeb.DeviceAuthorizationControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.DeviceAuthorizations.DeviceAuthorization
  alias OpenAgents.Repo

  test "a pending device authorization is digested and polling is paced", %{conn: conn} do
    created = post(conn, ~p"/api/v3/device/authorizations", %{})

    assert %{
             "device_code" => device_code,
             "user_code" => user_code,
             "verification_uri" => verification_uri,
             "verification_uri_complete" => verification_uri_complete,
             "expires_in" => expires_in,
             "interval" => interval
           } = json_response(created, 201)

    assert expires_in in 590..600
    assert interval == 5
    assert String.ends_with?(verification_uri, "/device")
    assert String.contains?(verification_uri_complete, URI.encode_www_form(user_code))
    assert get_resp_header(created, "cache-control") == ["no-store"]

    authorization = Repo.one!(DeviceAuthorization)
    refute authorization.device_code_digest == device_code
    refute authorization.user_code_digest == user_code
    refute inspect(authorization) =~ device_code
    refute inspect(authorization) =~ user_code

    pending =
      post(recycle(conn), ~p"/api/v3/device/authorizations/token", %{device_code: device_code})

    assert json_response(pending, 428) == %{"code" => "authorization_pending"}

    paced =
      post(recycle(conn), ~p"/api/v3/device/authorizations/token", %{device_code: device_code})

    assert json_response(paced, 429) == %{"code" => "slow_down"}
    assert get_resp_header(paced, "cache-control") == ["no-store"]
  end

  test "approval returns one PAT exactly once", %{conn: conn} do
    %{"device_code" => device_code, "user_code" => user_code} =
      conn
      |> post(~p"/api/v3/device/authorizations", %{})
      |> json_response(201)

    user = github_user("device-approval", "device-owner")
    assert {:ok, _authorization} = OpenAgents.DeviceAuthorizations.approve(user_code, user)

    claimed =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: device_code})

    assert %{
             "access_token" => "oa_pat_" <> _secret,
             "token_type" => "Bearer",
             "scope" => "chat:account forge:write",
             "expires_in" => expires_in
           } = json_response(claimed, 200)

    assert expires_in > 2_500_000

    repeated =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: device_code})

    assert json_response(repeated, 400) == %{"code" => "access_denied"}

    authorization = Repo.one!(DeviceAuthorization)
    assert authorization.state == "claimed"
    assert authorization.claimed_at
    assert authorization.api_token_id
  end

  test "unknown, denied, expired, and claimed codes share one refusal", %{conn: conn} do
    unknown =
      post(conn, ~p"/api/v3/device/authorizations/token", %{device_code: "unknown-device"})

    assert json_response(unknown, 400) == %{"code" => "access_denied"}

    %{"device_code" => denied_code, "user_code" => user_code} =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations", %{})
      |> json_response(201)

    user = github_user("device-denial")
    assert {:ok, _authorization} = OpenAgents.DeviceAuthorizations.deny(user_code, user)

    denied =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: denied_code})

    assert json_response(denied, 400) == %{"code" => "access_denied"}

    %{"device_code" => expired_code} =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations", %{})
      |> json_response(201)

    DeviceAuthorization
    |> Repo.all()
    |> Enum.find(&(&1.state == "pending"))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    expired =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: expired_code})

    assert json_response(expired, 400) == %{"code" => "access_denied"}
  end

  test "a privileged scope can be requested but only an operator may grant it", %{conn: conn} do
    %{"device_code" => device_code, "user_code" => user_code, "scope" => scope} =
      conn
      |> post(~p"/api/v3/device/authorizations", %{"scope" => "deployments:promote"})
      |> json_response(201)

    assert scope == "deployments:promote"

    ordinary = github_user("device-privileged-ordinary")
    assert {:error, :access_denied} = OpenAgents.DeviceAuthorizations.approve(user_code, ordinary)

    operator = github_user("device-privileged-operator")
    grant_operator(operator)
    assert {:ok, _authorization} = OpenAgents.DeviceAuthorizations.approve(user_code, operator)

    claimed =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: device_code})

    assert %{"scope" => "deployments:promote", "expires_in" => expires_in} =
             json_response(claimed, 200)

    # Seven days, the privileged ceiling, not the ordinary thirty.
    assert expires_in <= 7 * 24 * 60 * 60
  end

  # Signing in is what a person does before they use the product, so the token
  # it mints has to reach the product. `openagents coder` opens a thread, and a
  # login that names no scope used to mint a repository-only token that the
  # thread route refused, which read as "my login cannot open a chat".
  test "a login that names no scope can open a thread", %{conn: conn} do
    %{"device_code" => device_code, "user_code" => user_code} =
      conn
      |> post(~p"/api/v3/device/authorizations", %{})
      |> json_response(201)

    user = github_user("device-chat", "device-chat-owner")
    assert {:ok, _authorization} = OpenAgents.DeviceAuthorizations.approve(user_code, user)

    %{"access_token" => token, "scope" => scope} =
      conn
      |> recycle()
      |> post(~p"/api/v3/device/authorizations/token", %{device_code: device_code})
      |> json_response(200)

    assert scope == "chat:account forge:write"

    opened =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/v3/threads", %{"objective" => "run the coder"})

    assert %{"thread" => %{"id" => _id}, "grant" => %{"token" => _grant, "limits" => limits}} =
             json_response(opened, 201)

    # Signing in is also what raises the money: the thread is granted the
    # account credit, not the visitor's.
    assert limits["max_cost_microusd"] ==
             Application.fetch_env!(:openagents, :account_credit_microusd)
  end

  test "an unknown scope is refused rather than silently narrowed", %{conn: conn} do
    refused =
      post(conn, ~p"/api/v3/device/authorizations", %{"scope" => "deployments:everything"})

    assert json_response(refused, 400) == %{"code" => "invalid_scope"}
  end
end
