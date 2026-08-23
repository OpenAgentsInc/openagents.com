defmodule OpenAgentsWeb.ComputerControlApiTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens
  alias OpenAgents.Machines
  alias OpenAgents.Support.FakeController
  alias OpenAgents.Work

  @root "/tmp/openagents-computer-control-api"

  test "computer control is an independent human token scope", %{conn: conn} do
    user = github_user("computer-control-scope")

    assert build_conn()
           |> put_api_token(user, ["computer:control"])
           |> get(~p"/api/v3/computers")
           |> json_response(200) == %{
             "schema" => "openagents.computers.v1",
             "computers" => [],
             "pairing_enabled" => true
           }

    assert build_conn()
           |> put_api_token(user, ["box:control"])
           |> get(~p"/api/v3/computers")
           |> json_response(401) == %{"error" => %{"code" => "invalid_api_token"}}

    assert build_conn()
           |> put_api_token(user, ["computer:control"])
           |> get(~p"/api/v3/conversations/not-a-conversation/boxes")
           |> json_response(401) == %{"error" => %{"code" => "invalid_api_token"}}

    assert conn
           |> get(~p"/api/v3/computers")
           |> json_response(401) == %{"error" => %{"code" => "invalid_api_token"}}
  end

  test "human computer tokens list safe capability projections and probe a computer" do
    user = github_user("computer-control-list")
    machine = paired_machine(user, "listed-computer", ["codex"])
    token_conn = build_conn() |> put_api_token(user, ["computer:control"])

    listed =
      token_conn
      |> get(~p"/api/v3/computers")
      |> json_response(200)
      |> get_in(["computers", Access.at(0)])

    assert listed["id"] == machine.id
    assert listed["tier"] == "curated"
    assert listed["roots"] == [@root]
    assert listed["online"] == false
    assert [%{"id" => "codex"}] = listed["acp_agents"]
    refute Map.has_key?(listed, "last_probe")
    refute inspect(listed) =~ "token_digest"

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:probe, request_id, _payload, caller} ->
         FakeController.exit(caller, request_id, %{
           "acp_agents" => [
             %{"id" => "codex", "version" => "2.0", "private" => "hidden"}
           ],
           "private_probe_detail" => "hidden"
         })
       end}
    )

    probed =
      token_conn
      |> post(~p"/api/v3/computers/#{machine.id}/probe")
      |> json_response(200)

    assert probed["computer"]["online"]
    assert [%{"id" => "codex", "version" => "2.0"}] = probed["computer"]["acp_agents"]
    refute inspect(probed) =~ "private_probe_detail"
    refute inspect(probed) =~ "token_digest"
  end

  test "agent computer grants authorize the linked human authority and revoke immediately" do
    user = github_user("computer-control-agent-owner")
    {:ok, agent, credential} = register_agent("computer-control-agent")
    {:ok, link} = Agents.request_link(agent, user)
    {:ok, _linked} = Agents.accept_link(user, link.id)
    assert {:ok, grant} = Agents.grant_computer_control(user, agent)
    assert grant.target_kind == "computer"
    assert grant.scope == "computer:control"

    machine = paired_machine(user, "agent-computer", ["codex"])

    assert build_conn()
           |> bearer(credential)
           |> get(~p"/api/v3/computers")
           |> json_response(200)
           |> Map.get("computers")
           |> Enum.any?(&(&1["id"] == machine.id))

    assert {:ok, _revoked} = Agents.revoke_computer_control(user, agent)

    assert build_conn()
           |> bearer(credential)
           |> get(~p"/api/v3/computers")
           |> json_response(403) == %{
             "error" => %{"code" => "agent_computer_control_forbidden"}
           }
  end

  test "delegated Box and Computer grants do not cross-authorize routes", %{conn: conn} do
    owner = github_user("delegated-cross-kind-owner")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, box_agent, box_credential} = register_agent("delegated-box-only")
    {:ok, box_link} = Agents.request_link(box_agent, owner)
    {:ok, _linked} = Agents.accept_link(owner, box_link.id)
    assert {:ok, _box_grant} = Agents.grant_box_control(owner, box_agent)

    assert conn
           |> bearer(box_credential)
           |> get(~p"/api/v3/computers")
           |> json_response(403) == %{
             "error" => %{"code" => "agent_computer_control_forbidden"}
           }

    {:ok, computer_agent, computer_credential} = register_agent("delegated-computer-only")
    {:ok, computer_link} = Agents.request_link(computer_agent, owner)
    {:ok, _linked} = Agents.accept_link(owner, computer_link.id)
    assert {:ok, _computer_grant} = Agents.grant_computer_control(owner, computer_agent)

    assert conn
           |> bearer(computer_credential)
           |> get(~p"/api/v3/conversations/#{conversation.id}/boxes")
           |> json_response(403) == %{
             "error" => %{"code" => "agent_box_control_forbidden"}
           }
  end

  test "computer delegation enters the shared policy authority and scopes jobs to the owner" do
    user = github_user("computer-control-delegation")
    outsider = github_user("computer-control-outsider")
    machine = paired_machine(user, "delegated-computer", ["codex"])
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, _payload, caller} ->
         send(test_pid, {:agent_request, request_id, caller})
       end}
    )

    token_conn = build_conn() |> put_api_token(user, ["computer:control"])

    response =
      token_conn
      |> post(~p"/api/v3/computers/#{machine.id}/agent-jobs", %{
        "agent_id" => "codex",
        "prompt" => "do not echo this prompt",
        "cwd" => @root
      })
      |> json_response(202)

    job_id = response["job"]["id"]
    refute inspect(response) =~ "do not echo this prompt"
    assert_receive {:agent_request, _request_id, _caller}, 1_000

    assert build_conn()
           |> put_api_token(outsider, ["computer:control"])
           |> get(~p"/api/v3/computer-agent-jobs/#{job_id}")
           |> json_response(404) == %{"error" => "job_not_found"}

    [{pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job_id})
    ref = Process.monitor(pid)

    assert token_conn
           |> delete(~p"/api/v3/computer-agent-jobs/#{job_id}")
           |> json_response(202)
           |> Map.take(["job_id", "status"])
           |> Map.equal?(%{"job_id" => job_id, "status" => "stopping"})

    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
    assert %Work.Job{status: "cancelled"} = Work.get_job!(job_id)
  end

  test "delegation refuses missing probe agents and cwd outside declared roots" do
    user = github_user("computer-control-policy")
    machine = paired_machine(user, "policy-computer", ["claude"])
    start_supervised!({FakeController, machine_id: machine.id, script: fn _request -> :ok end})
    token_conn = build_conn() |> put_api_token(user, ["computer:control"])

    missing_agent =
      token_conn
      |> post(~p"/api/v3/computers/#{machine.id}/agent-jobs", %{
        "agent_id" => "codex",
        "prompt" => "bounded",
        "cwd" => @root
      })
      |> json_response(422)

    assert missing_agent["error"] == "agent_not_available"

    invalid_cwd =
      token_conn
      |> post(~p"/api/v3/computers/#{machine.id}/agent-jobs", %{
        "agent_id" => "claude",
        "prompt" => "bounded",
        "cwd" => "/tmp/outside"
      })
      |> json_response(422)

    assert invalid_cwd["error"] == "cwd_not_allowed"
  end

  defp paired_machine(user, name, agent_ids) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "curated",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => [@root]
             })

    assert {:ok, machine} = Machines.approve_pairing(user, pairing.code)

    assert {:ok, machine} =
             Machines.store_probe(machine, %{
               "acp_agents" => Enum.map(agent_ids, &%{"id" => &1, "version" => "1.0"})
             })

    machine
  end

  defp register_agent(handle) do
    Agents.register(%{
      "handle" => handle,
      "display_name" => handle,
      "registration_ip" => "192.0.2.125"
    })
  end

  defp put_api_token(conn, user, scopes) do
    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Computer API test", scopes: scopes, lifetime_days: 1})

    bearer(conn, plaintext)
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
