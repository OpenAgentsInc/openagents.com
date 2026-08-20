defmodule OpenAgentsWeb.ControllerPairingTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  alias OpenAgents.Machines

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
end
