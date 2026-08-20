defmodule OpenAgentsWeb.ComputerAgentJobsControllerTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Machines
  alias OpenAgents.Support.FakeController
  alias OpenAgents.Work

  @root "/tmp/openagents-agent-api"

  test "an API-started Codex job streams into ChatLive and posts its terminal report", %{
    conn: conn
  } do
    user = github_user("agent-api-live")
    machine = paired_machine(user, "codex-api-box", ["codex"])
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, payload, caller} ->
         send(test_pid, {:agent_request, request_id, payload, caller})
       end}
    )

    {:ok, view, _html} = live(browser_conn(conn, user), ~p"/chat")

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{machine.id}/agent-jobs", %{
        "agent_id" => "codex",
        "prompt" => "Reply with the word connected and make no changes.",
        "cwd" => @root
      })
      |> json_response(202)

    job_id = response["job"]["id"]
    assert response["job"]["status"] in ["queued", "running"]
    refute inspect(response) =~ "Reply with the word"

    assert_receive {:agent_request, request_id, payload, caller}, 1_000
    assert payload["agent_id"] == "codex"
    assert payload["cwd"] == @root
    assert payload["prompt"] == "Reply with the word connected and make no changes."

    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#delegation-live", "codex-api-box")
    assert has_element?(view, "#delegation-live", "codex")

    FakeController.chunk(caller, request_id, "connected")
    assert_push_event(view, "delegation:chunk", %{text: "connected"}, 1_000)

    job_ref = monitor_job!(job_id)

    FakeController.exit(caller, request_id, %{
      "status" => "completed",
      "stop_reason" => "end_turn",
      "session_id" => "codex-api-session",
      "duration_ms" => 25,
      "model" => "gpt-5.6-sol",
      "reasoning_effort" => "medium",
      "mode" => "agent-full-access",
      "detail" => ""
    })

    assert_receive {:DOWN, ^job_ref, :process, _pid, :normal}, 1_000
    job = Work.get_job!(job_id)
    assert job.status == "completed"
    assert job.report =~ "connected"
    assert job.report =~ "Model: gpt-5.6-sol · Reasoning: medium · Mode: agent-full-access"
    assert is_binary(job.report_message_id)

    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#messages-#{job.report_message_id}.message-row--report")

    terminal =
      build_conn()
      |> authenticated_api(user)
      |> get(~p"/api/computer-agent-jobs/#{job_id}")
      |> json_response(200)

    assert terminal["job"]["status"] == "completed"
    assert terminal["job"]["report"] =~ "connected"
    assert terminal["job"]["report_message_id"] == job.report_message_id
  end

  test "consecutive API delegations remain concurrent until explicitly stopped" do
    user = github_user("agent-api-concurrent")
    machine = paired_machine(user, "concurrent-box", ["codex"])
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, payload, caller} ->
         send(test_pid, {:agent_request, request_id, payload["prompt"], caller})
       end}
    )

    start_job = fn prompt ->
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{machine.id}/agent-jobs", %{
        "agent_id" => "codex",
        "prompt" => prompt,
        "cwd" => @root
      })
      |> json_response(202)
      |> get_in(["job", "id"])
    end

    first_id = start_job.("first concurrent job")
    second_id = start_job.("second concurrent job")

    assert_receive {:agent_request, first_request, "first concurrent job", first_caller}, 1_000
    assert_receive {:agent_request, second_request, "second concurrent job", second_caller}, 1_000
    assert Work.get_job!(first_id).status in ["queued", "running"]
    assert Work.get_job!(second_id).status in ["queued", "running"]

    first_ref = monitor_job!(first_id)
    second_ref = monitor_job!(second_id)
    FakeController.exit(first_caller, first_request, %{"status" => "completed"})
    FakeController.exit(second_caller, second_request, %{"status" => "completed"})
    assert_receive {:DOWN, ^first_ref, :process, _pid, :normal}, 1_000
    assert_receive {:DOWN, ^second_ref, :process, _pid, :normal}, 1_000
    assert Work.get_job!(first_id).status == "completed"
    assert Work.get_job!(second_id).status == "completed"
  end

  test "job reads and cancellation are owner scoped" do
    user = github_user("agent-api-cancel-owner")
    outsider = github_user("agent-api-cancel-outsider")
    machine = paired_machine(user, "cancel-box", ["codex"])
    test_pid = self()

    start_supervised!(
      {FakeController,
       machine_id: machine.id,
       script: fn {:agent, request_id, _payload, caller} ->
         send(test_pid, {:agent_request, request_id, caller})
       end}
    )

    %{"job" => %{"id" => job_id}} =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{machine.id}/agent-jobs", valid_params())
      |> json_response(202)

    assert_receive {:agent_request, _request_id, _caller}, 1_000

    foreign_read =
      build_conn()
      |> authenticated_api(outsider)
      |> get(~p"/api/computer-agent-jobs/#{job_id}")

    assert json_response(foreign_read, 404)["error"] == "job_not_found"

    job_ref = monitor_job!(job_id)

    cancelled =
      build_conn()
      |> authenticated_api(user)
      |> delete(~p"/api/computer-agent-jobs/#{job_id}")
      |> json_response(202)

    assert cancelled == %{"job_id" => job_id, "status" => "stopping"}
    assert_receive {:DOWN, ^job_ref, :process, _pid, :normal}, 1_000
    assert Work.get_job!(job_id).status == "cancelled"

    foreign_cancel =
      build_conn()
      |> authenticated_api(outsider)
      |> delete(~p"/api/computer-agent-jobs/#{job_id}")

    assert json_response(foreign_cancel, 404)["error"] == "job_not_found"
  end

  test "start returns typed policy errors before creating a job" do
    user = github_user("agent-api-errors")
    offline = paired_machine(user, "offline-box", ["codex"])

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{offline.id}/agent-jobs", valid_params())

    assert json_response(response, 409)["error"] == "computer_offline"

    missing_agent = paired_machine(user, "missing-agent-box", ["claude"])
    connect_noop(missing_agent.id)

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{missing_agent.id}/agent-jobs", valid_params())

    assert json_response(response, 422)["error"] == "agent_not_available"

    wrong_cwd = paired_machine(user, "wrong-cwd-box", ["codex"])
    connect_noop(wrong_cwd.id)

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{wrong_cwd.id}/agent-jobs", %{
        valid_params()
        | "cwd" => "/tmp/outside-declared-root"
      })

    assert json_response(response, 422)["error"] == "cwd_not_allowed"

    assert {:ok, _revoked} = Machines.revoke_machine(user, wrong_cwd.id)

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{wrong_cwd.id}/agent-jobs", valid_params())

    assert json_response(response, 409)["error"] == "computer_revoked"
  end

  test "disabled controller environments cannot start agent jobs" do
    user = github_user("agent-api-disabled")
    machine = paired_machine(user, "disabled-box", ["codex"])
    connect_noop(machine.id)

    previous = Application.fetch_env!(:openagents, :computer_controller_enabled)
    Application.put_env(:openagents, :computer_controller_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :computer_controller_enabled, previous) end)

    response =
      build_conn()
      |> authenticated_api(user)
      |> post(~p"/api/computers/#{machine.id}/agent-jobs", valid_params())

    assert json_response(response, 404)["error"] == "computer_controller_disabled"
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
               "acp_agents" =>
                 Enum.map(agent_ids, fn id ->
                   %{
                     "id" => id,
                     "source" => "operator",
                     "version" => "1.0",
                     "auth_ready" => true
                   }
                 end)
             })

    machine
  end

  defp connect_noop(machine_id) do
    start_supervised!(
      {FakeController,
       machine_id: machine_id, script: fn {_kind, _request_id, _payload, _caller} -> :ok end},
      id: {FakeController, machine_id}
    )
  end

  defp valid_params do
    %{
      "agent_id" => "codex",
      "prompt" => "Reply with connected and make no changes.",
      "cwd" => @root
    }
  end

  defp browser_conn(conn, user),
    do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp authenticated_api(conn, user) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> browser_conn(user)
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-csrf-token", csrf_token)
  end

  defp monitor_job!(job_id) do
    [{pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job_id})
    Process.monitor(pid)
  end
end
