defmodule OpenAgentsWeb.ControllerPairingTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Ecto.Query

  alias OpenAgents.Machines
  alias OpenAgents.Repo

  @create_params %{
    "name" => "pairing-box",
    "tier" => "probe",
    "platform" => "linux-x64",
    "agent_version" => "0.1.0",
    "roots" => ["/home/someone/code"]
  }

  test "full device pairing over the API", %{conn: conn} do
    created =
      conn
      |> post(~p"/controller/pairings", @create_params)
      |> json_response(200)

    assert %{
             "pairing_id" => pairing_id,
             "code" => code,
             "poll_secret" => poll_secret,
             "verify_url" => verify_url,
             "interval_seconds" => 3
           } = created

    assert URI.parse(verify_url).path == "/computers"
    assert code =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/

    pending =
      build_conn()
      |> put_req_header("x-pairing-secret", poll_secret)
      |> get(~p"/controller/pairings/#{pairing_id}")
      |> json_response(200)

    assert pending["status"] == "pending"

    {:ok, _machine} = Machines.approve_pairing(github_user("pairing-api"), code)

    approved =
      build_conn()
      |> put_req_header("x-pairing-secret", poll_secret)
      |> get(~p"/controller/pairings/#{pairing_id}")
      |> json_response(200)

    assert %{"status" => "approved", "token" => "smct_" <> _rest, "machine_id" => machine_id} =
             approved

    assert is_binary(machine_id)

    consumed =
      build_conn()
      |> put_req_header("x-pairing-secret", poll_secret)
      |> get(~p"/controller/pairings/#{pairing_id}")

    assert json_response(consumed, 404)["error"] == "pairing_not_found"
  end

  test "polling without the secret reveals nothing", %{conn: conn} do
    %{"pairing_id" => pairing_id} =
      conn |> post(~p"/controller/pairings", @create_params) |> json_response(200)

    response = build_conn() |> get(~p"/controller/pairings/#{pairing_id}")
    assert json_response(response, 404)["error"] == "pairing_not_found"
  end

  test "invalid pairing attributes are rejected", %{conn: conn} do
    response = post(conn, ~p"/controller/pairings", %{"name" => "", "tier" => "root"})
    assert json_response(response, 422)["error"] == "invalid_pairing"
  end

  test "the API is hidden when the feature is disabled", %{conn: conn} do
    original = Application.get_env(:openagents, :computer_controller_enabled)
    Application.put_env(:openagents, :computer_controller_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :computer_controller_enabled, original) end)

    response = post(conn, ~p"/controller/pairings", @create_params)
    assert json_response(response, 404)["error"] == "computer_controller_disabled"
  end

  test "machine status returns only the bounded caller projection", %{conn: conn} do
    user = github_user("machine-status-active")
    {machine_id, token} = approved_machine(conn, user)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/controller/status")

    assert %{
             "machine_id" => ^machine_id,
             "name" => "pairing-box",
             "status" => "active",
             "token_expires_at" => expires_at
           } = json_response(response, 200)

    assert is_binary(expires_at)
    refute response.resp_body =~ "token_digest"
    refute response.resp_body =~ "roots"
    refute response.resp_body =~ user.id
    refute response.resp_body =~ token
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "machine status distinguishes revoked, expired, unknown, and malformed credentials",
       %{conn: conn} do
    user = github_user("machine-status-errors")
    {machine_id, token} = approved_machine(conn, user)

    revoked =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/controller/status")

    OpenAgents.Machines.revoke_machine(user, machine_id)

    revoked_response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/controller/status")

    assert json_response(revoked_response, 401)["error"] == "machine_revoked"
    assert json_response(revoked, 200)["status"] == "active"

    {_expired_id, expired_token} =
      approved_machine(build_conn(), github_user("machine-status-expired"))

    {:ok, expired_machine} = Machines.authenticate_token(expired_token)

    backdated = DateTime.add(DateTime.utc_now(), -31, :day)
    expired_machine_id = expired_machine.id

    Repo.update_all(
      from(machine in OpenAgents.Machines.Machine, where: machine.id == ^expired_machine_id),
      set: [inserted_at: backdated]
    )

    Repo.get!(OpenAgents.Machines.Machine, expired_machine.id)
    |> Ecto.Changeset.change(token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    expired_response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> expired_token)
      |> get(~p"/controller/status")

    assert json_response(expired_response, 401)["error"] == "machine_expired"

    unknown_response =
      build_conn()
      |> put_req_header("authorization", "Bearer smct_unknown")
      |> get(~p"/controller/status")

    assert json_response(unknown_response, 401)["error"] == "machine_not_found"

    malformed_response =
      build_conn()
      |> put_req_header("authorization", "Basic malformed")
      |> get(~p"/controller/status")

    assert json_response(malformed_response, 401)["error"] == "invalid_machine_token"
  end

  defp approved_machine(conn, user) do
    created = conn |> post(~p"/controller/pairings", @create_params) |> json_response(200)
    {:ok, machine} = Machines.approve_pairing(user, created["code"])

    claimed =
      build_conn()
      |> put_req_header("x-pairing-secret", created["poll_secret"])
      |> get(~p"/controller/pairings/#{created["pairing_id"]}")
      |> json_response(200)

    assert claimed["machine_id"] == machine.id
    {machine.id, claimed["token"]}
  end
end
