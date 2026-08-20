defmodule OpenAgentsWeb.ComputersControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  @moduletag :skip
  alias OpenAgents.Computer
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Pairing
  alias OpenAgents.Repo

  @pairing_params %{
    "name" => "api-canary",
    "tier" => "curated",
    "platform" => "linux-x64",
    "agent_version" => "0.4.0",
    "roots" => ["/tmp/sarah-api-canary"]
  }

  test "the API drives pairing, claim, presence, inventory, and revoke without exposing tokens",
       %{
         conn: conn
       } do
    user = github_user("computers-api-lifecycle")
    created = create_pairing(conn)

    approved =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
        "code" => created["code"]
      })
      |> json_response(200)

    machine_id = approved["computer"]["id"]
    assert approved["computer"]["status"] == "active"
    assert approved["computer"]["online"] == false
    refute inspect(approved) =~ "smct_"

    claimed =
      build_conn()
      |> put_req_header("x-pairing-secret", created["poll_secret"])
      |> get(~p"/controller/pairings/#{created["pairing_id"]}")
      |> json_response(200)

    token = claimed["token"]
    assert {:ok, %{id: ^machine_id}} = Machines.authenticate_token(token)

    {:ok, machine} = Machines.get_machine(user.id, machine_id)

    agents =
      for index <- 1..18 do
        %{
          "id" => "agent-#{index}",
          "version" => String.duplicate("v", 100),
          "source" => "operator",
          "auth_ready" => true,
          "model" => "gpt-5.6-sol",
          "reasoning_effort" => "medium",
          "mode" => "agent-full-access",
          "private_detail" => "not projected"
        }
      end

    assert {:ok, _machine} = Machines.store_probe(machine, %{"acp_agents" => agents})

    assert {:ok, _registration} = Computer.register(machine_id)
    on_exit(fn -> Computer.unregister(machine_id) end)

    inventory =
      build_conn()
      |> authenticated_api(user)
      |> get(~p"/api/computers")
      |> json_response(200)

    assert %{
             "schema" => "sarah.computers.v1",
             "pairing_enabled" => true,
             "computers" => [listed]
           } = inventory

    assert %{"id" => ^machine_id, "online" => true, "status" => "active"} = listed
    assert length(listed["acp_agents"]) == 16

    assert %{
             "model" => "gpt-5.6-sol",
             "reasoning_effort" => "medium",
             "mode" => "agent-full-access"
           } = hd(listed["acp_agents"])

    refute inspect(listed) =~ "private_detail"

    revoked =
      build_conn()
      |> authenticated_api(user)
      |> delete(~p"/api/computers/#{machine_id}")
      |> json_response(200)

    assert revoked["computer"]["status"] == "revoked"
    assert revoked["computer"]["online"] == false
    assert {:error, :machine_revoked} = Machines.authenticate_token(token)
  end

  test "approval binds the pairing id to its code and consumes the code once", %{conn: conn} do
    user = github_user("computers-api-binding")
    first = create_pairing(conn)
    second = create_pairing(build_conn())

    mismatch =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/pairings/#{first["pairing_id"]}/approve", %{
        "code" => second["code"]
      })

    assert json_response(mismatch, 404)["error"] == "pairing_not_found"

    path = ~p"/api/computers/pairings/#{first["pairing_id"]}/approve"
    params = %{"code" => first["code"]}
    assert build_conn() |> authenticated_api(user) |> post(path, params) |> json_response(200)

    consumed = build_conn() |> authenticated_api(user) |> post(path, params)
    assert json_response(consumed, 409)["error"] == "pairing_consumed"
  end

  test "expired codes and disabled pairing return typed outcomes", %{conn: conn} do
    user = github_user("computers-api-errors")
    created = create_pairing(conn)

    Repo.get!(Pairing, created["pairing_id"])
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    expired =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
        "code" => created["code"]
      })

    assert json_response(expired, 410)["error"] == "pairing_expired"

    previous = Application.fetch_env!(:openagents, :computer_controller_enabled)
    Application.put_env(:openagents, :computer_controller_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :computer_controller_enabled, previous) end)

    disabled =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
        "code" => created["code"]
      })

    assert json_response(disabled, 404)["error"] == "computer_controller_disabled"
  end

  test "computer inventory and revocation are owner scoped", %{conn: conn} do
    owner = github_user("computers-api-owner")
    outsider = github_user("computers-api-outsider")
    created = create_pairing(conn)

    %{"computer" => %{"id" => machine_id}} =
      build_conn()
      |> authenticated_api(owner)
      |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
        "code" => created["code"]
      })
      |> json_response(200)

    assert %{"computers" => []} =
             build_conn()
             |> authenticated_api(outsider)
             |> get(~p"/api/computers")
             |> json_response(200)

    response =
      build_conn()
      |> authenticated_api(outsider)
      |> delete(~p"/api/computers/#{machine_id}")

    assert json_response(response, 404)["error"] == "computer_not_found"
    assert {:ok, %{status: "active"}} = Machines.get_machine(owner.id, machine_id)
  end

  test "approval maps the active-computer capacity boundary" do
    user = github_user("computers-api-capacity")

    for _index <- 1..8 do
      created = create_pairing(build_conn())

      assert build_conn()
             |> authenticated_api(user)
             |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
               "code" => created["code"]
             })
             |> json_response(200)
    end

    ninth = create_pairing(build_conn())

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/pairings/#{ninth["pairing_id"]}/approve", %{
        "code" => ninth["code"]
      })

    assert json_response(response, 409)["error"] == "computer_capacity_reached"
  end

  test "the lifecycle API requires an active browser session", %{conn: conn} do
    response =
      conn
      |> init_test_session(%{})
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/computers")

    assert json_response(response, 401)["error"] == "authentication_required"
  end

  test "mutations require the browser session's CSRF token", %{conn: conn} do
    user = github_user("computers-api-csrf")
    created = create_pairing(conn)

    browser =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})
      |> get(~p"/computers")

    assert is_binary(get_session(browser, "_csrf_token"))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      browser
      |> recycle()
      |> enable_csrf_protection()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-csrf-token", "invalid")
      |> post(~p"/api/computers/pairings/#{created["pairing_id"]}/approve", %{
        "code" => created["code"]
      })
    end
  end

  defp create_pairing(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> post(~p"/controller/pairings", @pairing_params)
    |> json_response(200)
  end

  defp authenticated_api(conn, user) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-csrf-token", csrf_token)
  end

  defp enable_csrf_protection(conn) do
    %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
  end
end
