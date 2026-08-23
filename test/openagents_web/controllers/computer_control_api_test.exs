defmodule OpenAgentsWeb.ComputerControlApiTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Agents
  alias OpenAgents.ApiTokens
  alias OpenAgents.Forge.{AssignmentCredential, AssignmentCredentialVault, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Machines
  alias OpenAgents.Repo
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

    assert build_conn()
           |> bearer(credential)
           |> patch(~p"/api/v3/computers/#{machine.id}", %{
             "scoped_forge_credentials_enabled" => true
           })
           |> api_error_code(401) == "unauthenticated"

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

  test "Computer assignments report opt-in refusal but continue without push authority" do
    user = github_user("computer-assignment-no-opt-in")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    repository = repository_with_member_fixture(user)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Computer assignment"})
    machine = paired_machine(user, "assignment-no-opt-in", ["codex"])
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, payload, caller} ->
         send(test_pid, {:assignment_request, request_id, payload, caller})
       end}
    )

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/computers/#{machine.id}/assignments", %{
        "repository_id" => repository.id,
        "issue_number" => issue.number,
        "branch" => "agent/computer-#{issue.number}",
        "agent_id" => "codex",
        "prompt" => "Implement the issue",
        "cwd" => @root
      })
      |> json_response(202)

    assert response["assignment"]["credential_delivery"] == %{
             "status" => "refused",
             "reason" => "computer_scoped_forge_credentials_not_enabled"
           }

    assert_receive {:assignment_request, request_id, payload, caller}, 1_000
    refute Map.has_key?(payload, "assignment_credential")

    assert {:error, :invalid_assignment_credential} =
             Assignments.authenticate("oa_assignment_fake")

    assignment_id = response["assignment"]["id"]

    job =
      Repo.one!(
        from j in Work.Job,
          where: fragment("?->>'assignment_id'", j.delegation) == ^assignment_id
      )

    [{job_pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job.id})
    ref = Process.monitor(job_pid)
    FakeController.exit(caller, request_id, %{"status" => "completed", "output" => "done"})
    assert_receive {:DOWN, ^ref, :process, ^job_pid, :normal}, 1_000
  end

  test "owners can change the scoped forge credential policy and withdraw active credentials" do
    user = github_user("computer-assignment-policy-update")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    repository = repository_with_member_fixture(user)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Policy update"})
    machine = paired_machine(user, "assignment-policy-update", ["codex"], true)
    test_pid = self()

    controller =
      start_supervised!(
        {FakeController,
         machine_id: machine.id,
         script: fn {:agent, request_id, payload, caller} ->
           send(test_pid, {:assignment_request, request_id, payload, caller})
         end}
      )

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/computers/#{machine.id}/assignments", %{
        "repository_id" => repository.id,
        "issue_number" => issue.number,
        "branch" => "agent/policy-#{issue.number}",
        "agent_id" => "codex",
        "prompt" => "Implement the issue",
        "cwd" => @root
      })
      |> json_response(202)

    assignment_id = response["assignment"]["id"]
    assert response["assignment"]["credential_delivery"] == %{"status" => "enabled"}
    assert_receive {:assignment_request, _request_id, _payload, _caller}, 1_000

    updated =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> patch(~p"/api/v3/computers/#{machine.id}", %{
        "scoped_forge_credentials_enabled" => false
      })
      |> json_response(200)

    assert updated["computer"]["scoped_forge_credentials_enabled"] == false
    assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
    assert assignment.state == "failed"
    assert assignment.failure_reason == "scoped_forge_credentials_disabled"
    assert assignment.credential_delivery_status == "enabled"
    assert Assignments.credential(assignment).revoked_at
    assert AssignmentCredentialVault.take(assignment_id) == nil

    job =
      Repo.one!(
        from j in Work.Job,
          where: fragment("?->>'assignment_id'", j.delegation) == ^assignment_id
      )

    [{job_pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job.id})
    ref = Process.monitor(job_pid)
    assert GenServer.stop(controller, :normal) == :ok
    assert_receive {:DOWN, ^ref, :process, ^job_pid, :normal}, 1_000
  end

  test "controller disconnect finishes the assignment and revokes its credential" do
    user = github_user("computer-assignment-disconnect")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    repository = repository_with_member_fixture(user)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Controller disconnect"})
    machine = paired_machine(user, "assignment-disconnect", ["codex"], true)
    test_pid = self()

    controller =
      start_supervised!(
        {FakeController,
         machine_id: machine.id,
         script: fn {:agent, request_id, payload, caller} ->
           send(test_pid, {:assignment_request, request_id, payload, caller})
         end}
      )

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/computers/#{machine.id}/assignments", %{
        "repository_id" => repository.id,
        "issue_number" => issue.number,
        "branch" => "agent/disconnect-#{issue.number}",
        "agent_id" => "codex",
        "prompt" => "Implement the issue",
        "cwd" => @root
      })
      |> json_response(202)

    assignment_id = response["assignment"]["id"]
    assert_receive {:assignment_request, _request_id, _payload, _caller}, 1_000

    job =
      Repo.one!(
        from j in Work.Job,
          where: fragment("?->>'assignment_id'", j.delegation) == ^assignment_id
      )

    [{job_pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job.id})
    ref = Process.monitor(job_pid)
    assert GenServer.stop(controller, :normal) == :ok
    assert_receive {:DOWN, ^ref, :process, ^job_pid, :normal}, 1_000

    assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
    assert assignment.state == "failed"
    assert assignment.failure_reason == "machine_disconnected"
    assert Assignments.credential(assignment).revoked_at
    assert AssignmentCredentialVault.take(assignment_id) == nil
  end

  test "Computer assignment credentials are sent only in the agent frame and revoked on completion" do
    user = github_user("computer-assignment-opt-in")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    repository = repository_with_member_fixture(user)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Computer assignment credential"})
    machine = paired_machine(user, "assignment-opt-in", ["codex"], true)
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, payload, caller} ->
         send(test_pid, {:assignment_request, request_id, payload, caller})
       end}
    )

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/computers/#{machine.id}/assignments", %{
        "repository_id" => repository.id,
        "issue_number" => issue.number,
        "branch" => "agent/computer-#{issue.number}",
        "agent_id" => "codex",
        "prompt" => "Implement the issue",
        "cwd" => @root
      })
      |> json_response(202)

    assignment_id = response["assignment"]["id"]
    assert_receive {:assignment_request, request_id, payload, caller}, 1_000
    credential = payload["assignment_credential"]
    assert is_binary(credential)
    assert String.starts_with?(credential, "oa_assignment_")
    refute response |> inspect() =~ credential
    assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
    assert %AssignmentCredential{} = Assignments.credential(assignment)

    job =
      Repo.one!(
        from j in Work.Job,
          where: fragment("?->>'assignment_id'", j.delegation) == ^assignment_id
      )

    [{job_pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job.id})

    ref = Process.monitor(job_pid)
    FakeController.exit(caller, request_id, %{"status" => "completed", "output" => "done"})
    assert_receive {:DOWN, ^ref, :process, ^job_pid, :normal}, 1_000

    assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
    assert assignment.state == "completed"
    assert Assignments.credential(assignment).revoked_at
    assert AssignmentCredentialVault.take(assignment_id) == nil
    refute Repo.get!(Work.Job, job.id).report =~ credential
  end

  defp paired_machine(user, name, agent_ids, scoped_forge_credentials_enabled \\ false) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "curated",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => [@root]
             })

    assert {:ok, machine} =
             Machines.approve_pairing(user, pairing.code,
               scoped_forge_credentials_enabled: scoped_forge_credentials_enabled
             )

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
