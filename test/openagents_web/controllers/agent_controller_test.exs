defmodule OpenAgentsWeb.AgentControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Agents

  test "registers an agent and returns a one-time credential", %{conn: conn} do
    conn =
      post(conn, "/api/v3/agents/register", %{
        "handle" => "controller-bot",
        "display_name" => "Controller bot"
      })

    response = json_response(conn, 201)

    assert %{
             "agent" => %{"handle" => "controller-bot", "status" => "active"},
             "token" => "oa_agent_" <> _credential,
             "warning" => warning
           } = response

    assert warning =~ "shown once"
    refute get_in(response, ["agent", "token"])
  end

  test "rejects duplicate and malformed handles with typed errors", %{conn: conn} do
    assert %{"agent" => _agent} =
             conn
             |> post("/api/v3/agents/register", %{
               "handle" => "duplicate-bot",
               "display_name" => "Duplicate bot"
             })
             |> json_response(201)

    duplicate =
      post(conn, "/api/v3/agents/register", %{
        "handle" => "duplicate-bot",
        "display_name" => "Duplicate bot"
      })

    assert json_response(duplicate, 422)["error"]["code"] == "handle_unavailable"

    malformed =
      post(conn, "/api/v3/agents/register", %{
        "handle" => "bot--name",
        "display_name" => "Malformed bot"
      })

    assert json_response(malformed, 422)["error"]["code"] == "confusable_handle"
  end

  test "rejects reserved handles through the controller", %{conn: conn} do
    conn =
      post(conn, "/api/v3/agents/register", %{
        "handle" => "admin",
        "display_name" => "Admin bot"
      })

    assert json_response(conn, 422)["error"]["code"] == "handle_unavailable"
  end

  test "returns the documented rate-limit envelope from application configuration", %{conn: conn} do
    previous = Application.get_env(:openagents, :agent_registration_per_ip)
    Application.put_env(:openagents, :agent_registration_per_ip, 0)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:openagents, :agent_registration_per_ip)
      else
        Application.put_env(:openagents, :agent_registration_per_ip, previous)
      end
    end)

    conn =
      post(conn, "/api/v3/agents/register", %{
        "handle" => "limited-bot",
        "display_name" => "Limited bot"
      })

    assert %{"error" => %{"code" => "registration_rate_limited"}, "window_seconds" => window} =
             json_response(conn, 429)

    assert is_integer(window)
  end

  test "rotates a credential while retaining the old credential", %{conn: conn} do
    {:ok, _agent, credential} =
      Agents.register(%{
        handle: "rotate-controller-bot",
        display_name: "Rotate controller bot",
        registration_ip: "192.0.2.32"
      })

    rotated =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post("/api/v3/agent/credentials", %{"name" => "rotated"})

    assert %{
             "credential" => "oa_agent_" <> new_credential,
             "token" => %{"name" => "rotated"}
           } = json_response(rotated, 201)

    assert {:ok, _agent, _token} = Agents.authenticate("oa_agent_" <> new_credential)

    old_still_works =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{credential}")
      |> get("/api/v3/agent")

    assert json_response(old_still_works, 200)["agent"]["handle"] == "rotate-controller-bot"
  end

  test "returns a public agent profile and authenticates the current-agent route", %{conn: conn} do
    {:ok, agent, credential} =
      Agents.register(%{
        "handle" => "profile-bot",
        "display_name" => "Profile bot",
        "registration_ip" => "192.0.2.30"
      })

    profile = get(conn, "/api/v3/agents/profile-bot")
    assert json_response(profile, 200)["agent"]["id"] == agent.id

    current =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> get("/api/v3/agent")

    assert json_response(current, 200)["agent"]["handle"] == "profile-bot"
  end

  test "rejects agent credentials on named human-only routes", %{conn: conn} do
    {:ok, _agent, credential} =
      Agents.register(%{
        "handle" => "restricted-bot",
        "display_name" => "Restricted bot",
        "registration_ip" => "192.0.2.31"
      })

    operator =
      conn
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post("/api/operator/agents/restricted-bot/suspend", %{"reason" => "test"})

    assert operator.status == 401

    promotion =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post("/api/v3/repos/test-owner/test-repo/deployments/1/approvals", %{})

    assert promotion.status == 401

    membership =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{credential}")
      |> patch("/api/v3/repos/test-owner/test-repo/issues/1", %{"title" => "test"})

    assert membership.status == 401

    tip =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{credential}")
      |> post("/api/v3/forum/posts/1/tips", %{"amount" => "1"})

    assert tip.status == 401
  end
end
