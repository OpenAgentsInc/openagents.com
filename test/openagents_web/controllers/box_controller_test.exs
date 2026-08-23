defmodule OpenAgentsWeb.BoxControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Agents, Conversations, Issues, Repo}
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Issues.Comment

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.merge(original_api || [],
        base_url: "https://box-api.internal",
        poll_interval_ms: 0,
        poll_attempts: 3,
        request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
      )
    )

    Application.put_env(:openagents, :box_api_key, "box_api_test_credential")
    Req.Test.stub(__MODULE__, fn request -> Req.Test.json(request, box_body()) end)

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    :ok
  end

  test "human box control token completes the create, command, list, show, and stop cycle", %{
    conn: conn
  } do
    user = github_user("api-token-box-api-cycle")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes"
      Req.Test.json(request, box_body())
    end)

    create_response =
      conn
      |> put_box_api_token("box-api-cycle")
      |> post(box_path(conversation.id), %{})
      |> json_response(201)

    box_id = create_response["box"]["box_id"]
    assert create_response["box"]["state"] == "ready"
    refute Map.has_key?(create_response["box"], "desktopUrl")

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/#{box_id}/commands"
      Req.Test.json(request, command_body())
    end)

    command_response =
      conn
      |> put_box_api_token("box-api-cycle")
      |> post("#{box_path(conversation.id)}/#{box_id}/commands", %{"command" => "echo hi"})
      |> json_response(200)

    assert command_response["result"]["exit_code"] == 0
    assert command_response["result"]["stdout"] == "hi\n"

    Req.Test.stub(__MODULE__, fn request -> Req.Test.json(request, box_body()) end)

    assert %{"boxes" => [%{"box_id" => ^box_id}]} =
             conn
             |> put_box_api_token("box-api-cycle")
             |> get(box_path(conversation.id))
             |> json_response(200)

    assert %{"box" => %{"box_id" => ^box_id}} =
             conn
             |> put_box_api_token("box-api-cycle")
             |> get("#{box_path(conversation.id)}/#{box_id}")
             |> json_response(200)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/#{box_id}/stop"
      Req.Test.json(request, box_body(%{"state" => "archiving"}))
    end)

    assert %{"box" => %{"box_id" => ^box_id, "state" => "archiving"}} =
             conn
             |> put_box_api_token("box-api-cycle")
             |> post("#{box_path(conversation.id)}/#{box_id}/stop", %{})
             |> json_response(200)
  end

  test "a token without box control is refused on every route", %{conn: conn} do
    user = github_user("api-token-box-api-auth")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box_id = "bx_8bhkse3n"

    paths = [
      {:get, box_path(conversation.id), %{}},
      {:post, box_path(conversation.id), %{}},
      {:get, "#{box_path(conversation.id)}/#{box_id}", %{}},
      {:post, "#{box_path(conversation.id)}/#{box_id}/commands", %{"command" => "id"}},
      {:post, "#{box_path(conversation.id)}/#{box_id}/stop", %{}}
    ]

    for {method, path, params} <- paths do
      response =
        conn
        |> put_forge_api_token("box-api-auth")
        |> request(method, path, params)

      assert response.status == 401

      assert json_response(response, 401) == %{
               "error" => %{"code" => "invalid_api_token"}
             }
    end
  end

  test "an agent credential receives a typed refusal on every route", %{conn: conn} do
    {:ok, _agent, credential} =
      OpenAgents.Agents.register(%{
        "handle" => "box-agent-auth",
        "display_name" => "Box agent",
        "registration_ip" => "198.51.100.21"
      })

    {:ok, conversation} = Conversations.ensure_conversation(github_user("box-agent-owner"))
    authorization = "Bearer " <> credential

    for {method, path, params} <- [
          {:get, box_path(conversation.id), %{}},
          {:post, box_path(conversation.id), %{}},
          {:get, "#{box_path(conversation.id)}/bx_8bhkse3n", %{}},
          {:post, "#{box_path(conversation.id)}/bx_8bhkse3n/commands", %{"command" => "id"}},
          {:post, "#{box_path(conversation.id)}/bx_8bhkse3n/stop", %{}}
        ] do
      response =
        conn
        |> put_req_header("authorization", authorization)
        |> request(method, path, params)

      assert response.status == 403

      assert json_response(response, 403) == %{
               "error" => %{"code" => "agent_box_control_forbidden"}
             }
    end
  end

  test "a linked agent can list and stop a Box, then loses access when revoked", %{conn: conn} do
    owner = github_user("box-agent-control-owner")
    {:ok, conversation} = Conversations.ensure_conversation(owner)
    box = insert_box(conversation.id, "bx_8bhkse3n")

    {:ok, agent, credential} =
      Agents.register(%{
        "handle" => "box-agent-control",
        "display_name" => "Box control agent",
        "registration_ip" => "198.51.100.61"
      })

    {:ok, link} = Agents.request_link(agent, owner)
    {:ok, _linked} = Agents.accept_link(owner, link.id)
    assert {:ok, _grant} = Agents.grant_box_control(owner, agent)
    authorization = "Bearer " <> credential

    assert %{"boxes" => [%{"box_id" => "bx_8bhkse3n"}]} =
             conn
             |> put_req_header("authorization", authorization)
             |> get(box_path(conversation.id))
             |> json_response(200)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/#{box.box_id}/stop"
      Req.Test.json(request, box_body(%{"state" => "archiving"}))
    end)

    assert %{"box" => %{"box_id" => "bx_8bhkse3n", "state" => "archiving"}} =
             conn
             |> put_req_header("authorization", authorization)
             |> post("#{box_path(conversation.id)}/#{box.box_id}/stop", %{})
             |> json_response(200)

    assert {:ok, _revoked} = Agents.revoke_box_control(owner, agent)

    assert conn
           |> put_req_header("authorization", authorization)
           |> get(box_path(conversation.id))
           |> json_response(403) == %{
             "error" => %{"code" => "agent_box_control_forbidden"}
           }
  end

  test "a linked agent assignment uses the granting human's conversation owner", %{conn: conn} do
    owner = repository_user_fixture("box-assignment-agent-owner")
    {:ok, conversation} = Conversations.ensure_conversation(owner)
    box = insert_box(conversation.id, "bx_8bhkse3n")
    repository = repository_with_member_fixture(owner)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Agent assignment target"})

    {:ok, agent, credential} =
      Agents.register(%{
        "handle" => "box-assignment-agent",
        "display_name" => "Box assignment agent",
        "registration_ip" => "198.51.100.62"
      })

    {:ok, link} = Agents.request_link(agent, owner)
    {:ok, _linked} = Agents.accept_link(owner, link.id)
    assert {:ok, _grant} = Agents.grant_box_control(owner, agent)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "GET"
      assert request.request_path == "/boxes/#{box.box_id}"
      Req.Test.json(request, box_body())
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/#{box.box_id}/commands"
      Req.Test.json(request, %{"stdout" => "123\n"})
    end)

    Req.Test.stub(__MODULE__, fn request ->
      Req.Test.json(request, %{"stdout" => "OA_PRESENT=0\n"})
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> credential)
      |> post(
        "/api/v3/conversations/#{conversation.id}/boxes/#{box.box_id}/assignments",
        %{
          "repository_id" => repository.id,
          "issue_number" => issue.number,
          "branch" => "agent/issue-#{issue.number}",
          "command" => "echo assigned"
        }
      )
      |> json_response(202)

    assignment_id = response["assignment"]["id"]
    assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
    assert assignment.requesting_principal["type"] == "agent"
    assert assignment.requesting_principal["id"] == agent.id
    assert Agents.box_control_owner(agent).id == owner.id
    assert %Comment{author_agent_id: agent_id} = Repo.get_by(Comment, issue_id: issue.id)
    assert agent_id == agent.id
  end

  test "a foreign box returns 404 without an outbound provider request", %{conn: conn} do
    owner = github_user("api-token-box-api-owner")
    {:ok, conversation} = Conversations.ensure_conversation(owner)

    {:ok, foreign_conversation} =
      Conversations.ensure_conversation(github_user("box-api-foreign"))

    insert_box(foreign_conversation.id, "bx_8bhkse3n")

    Req.Test.stub(__MODULE__, fn request ->
      send(self(), :unexpected_box_provider_request)
      Req.Test.json(request, box_body())
    end)

    assert conn
           |> put_box_api_token("box-api-owner")
           |> post("#{box_path(conversation.id)}/bx_8bhkse3n/commands", %{"command" => "id"})
           |> json_response(404) == %{"error" => %{"code" => "box_not_found"}}

    refute_receive :unexpected_box_provider_request
  end

  test "provider failures use typed status and error mappings", %{conn: conn} do
    user_key = "box-api-provider-errors"
    user = github_user("api-token-" <> user_key)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    for {status, error_code, response_status} <- [
          {402, "box_billing_required", 402},
          {429, "box_provider_rate_limited", 429},
          {409, "box_provider_request_refused", 502}
        ] do
      Req.Test.expect(__MODULE__, fn request ->
        request |> Plug.Conn.put_status(status) |> Req.Test.json(%{"code" => "provider detail"})
      end)

      response =
        conn
        |> put_box_api_token(user_key)
        |> post(box_path(conversation.id), %{})

      assert json_response(response, response_status) == %{"error" => %{"code" => error_code}}
      refute response.resp_body =~ "provider detail"
    end

    Req.Test.expect(__MODULE__, fn request -> Req.Test.transport_error(request, :econnrefused) end)

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(503) == %{"error" => %{"code" => "box_unreachable"}}

    Req.Test.expect(__MODULE__, fn request -> Req.Test.json(request, []) end)

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(502) == %{
             "error" => %{"code" => "box_provider_response_invalid"}
           }

    Application.delete_env(:openagents, :box_api_key)

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(503) == %{"error" => %{"code" => "box_not_configured"}}
  end

  test "quota, redaction, bounds, timeout, and provider URLs stay safe", %{conn: conn} do
    user_key = "box-api-safe-output"
    user = github_user("api-token-" <> user_key)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    for index <- 1..OpenAgents.Box.maximum_active_boxes() do
      insert_box(conversation.id, "bx_aaaaaaa#{Enum.at(~w(2 3 4 5 6 7 8 9 a b), index - 1)}")
    end

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(409) == %{"error" => %{"code" => "box_quota_reached"}}

    insert_box(conversation.id, "bx_8bhkse3n")
    large_output = String.duplicate("x", 30_000)

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{
        "exitCode" => 124,
        "stdout" => "sk-or-v1-abcdefghijklmnop " <> large_output,
        "stderr" =>
          "clone https://openagents.com/OpenAgentsInc/openagents.com\n" <>
            "https://viewer.ascii.dev/desktop?access_token=secret",
        "timedOut" => true,
        "desktopUrl" => "https://viewer.ascii.dev/desktop?token=secret"
      })
    end)

    response =
      conn
      |> put_box_api_token(user_key)
      |> post("#{box_path(conversation.id)}/bx_8bhkse3n/commands", %{"command" => "id"})
      |> json_response(200)

    result = response["result"]
    assert result["exit_code"] == 124
    assert result["timed_out"]
    assert result["stdout_truncated"]

    assert result["stderr"] ==
             "clone https://openagents.com/OpenAgentsInc/openagents.com\n[REDACTED_URL]"

    refute response["result"]["stdout"] =~ "sk-or-v1"
    refute inspect(response) =~ "desktopUrl"
    refute inspect(response) =~ "viewer.ascii.dev"
    refute inspect(response) =~ "access_token"
  end

  test "a foreign conversation returns 404 without an outbound provider request", %{
    conn: conn
  } do
    {:ok, _owner_conversation} =
      Conversations.ensure_conversation(github_user("api-token-box-api-isolation"))

    {:ok, foreign_conversation} =
      Conversations.ensure_conversation(github_user("box-api-foreign-conversation"))

    insert_box(foreign_conversation.id, "bx_8bhkse3n")

    Req.Test.stub(__MODULE__, fn request ->
      send(self(), :unexpected_box_provider_request)
      Req.Test.json(request, box_body())
    end)

    paths = [
      {:get, box_path(foreign_conversation.id), %{}},
      {:post, box_path(foreign_conversation.id), %{}},
      {:get, "#{box_path(foreign_conversation.id)}/bx_8bhkse3n", %{}},
      {:post, "#{box_path(foreign_conversation.id)}/bx_8bhkse3n/commands",
       %{
         "command" => "id"
       }},
      {:post, "#{box_path(foreign_conversation.id)}/bx_8bhkse3n/stop", %{}}
    ]

    for {method, path, params} <- paths do
      response =
        conn
        |> put_box_api_token("box-api-isolation")
        |> request(method, path, params)

      assert response.status == 404

      assert json_response(response, 404) == %{
               "error" => %{"code" => "conversation_not_found"}
             }
    end

    refute_receive :unexpected_box_provider_request
  end

  test "creates and commands are rate limited per human principal", %{conn: conn} do
    original_api = Application.get_env(:openagents, :box_api)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.merge(original_api || [], create_rate_limit: 1, command_rate_limit: 1)
    )

    on_exit(fn -> restore_env(:box_api, original_api) end)

    user_key = "box-api-rate-limit"
    user = github_user("api-token-" <> user_key)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    Req.Test.expect(__MODULE__, fn request -> Req.Test.json(request, box_body()) end)

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(201)

    assert conn
           |> put_box_api_token(user_key)
           |> post(box_path(conversation.id), %{})
           |> json_response(429) == %{"error" => %{"code" => "box_api_rate_limited"}}

    Req.Test.expect(__MODULE__, fn request -> Req.Test.json(request, command_body()) end)

    command_path = "#{box_path(conversation.id)}/bx_8bhkse3n/commands"

    assert conn
           |> put_box_api_token(user_key)
           |> post(command_path, %{"command" => "id"})
           |> json_response(200)

    assert conn
           |> put_box_api_token(user_key)
           |> post(command_path, %{"command" => "id"})
           |> json_response(429) == %{"error" => %{"code" => "box_api_rate_limited"}}
  end

  test "rate-limit buckets are shared across request processes" do
    original_api = Application.get_env(:openagents, :box_api)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.merge(original_api || [], create_rate_limit: 1)
    )

    on_exit(fn -> restore_env(:box_api, original_api) end)

    first = Task.async(fn -> OpenAgentsWeb.BoxRateLimiter.allow?("shared-principal", :create) end)
    assert Task.await(first) == :ok

    second =
      Task.async(fn -> OpenAgentsWeb.BoxRateLimiter.allow?("shared-principal", :create) end)

    assert Task.await(second) == {:error, :rate_limited}
  end

  defp box_path(conversation_id), do: "/api/v3/conversations/#{conversation_id}/boxes"

  defp box_body(overrides \\ %{}) do
    %{
      "box" =>
        Map.merge(
          %{"id" => "bx_8bhkse3n", "state" => "ready", "setupStatus" => "done"},
          overrides
        )
    }
  end

  defp command_body do
    %{
      "exitCode" => 0,
      "stdout" => "hi\n",
      "stderr" => "",
      "timedOut" => false
    }
  end

  defp insert_box(conversation_id, box_id) do
    %ConversationBox{}
    |> ConversationBox.changeset(%{
      conversation_id: conversation_id,
      box_id: box_id,
      state: "ready",
      setup_status: "done"
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp request(conn, :get, path, _params), do: get(conn, path)
  defp request(conn, :post, path, params), do: post(conn, path, params)
end
