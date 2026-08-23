defmodule OpenAgentsWeb.DelegationsControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Agents, ApiTokens, Conversations, Machines, Repo, Work}
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
  alias OpenAgents.Support.FakeController
  alias OpenAgents.Work.Job

  @root "/tmp/openagents-unified-delegation"

  test "inventory lists only the target kinds held by the credential", %{conn: conn} do
    user = github_user("unified-inventory")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx-unified-inventory", "build-box")
    machine_id = paired_machine(user, "build-computer", ["codex"]).id

    response =
      conn
      |> put_api_token(user, ["computer:control"])
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegation-targets")
      |> json_response(200)

    assert response["schema"] == "openagents.delegation_targets.v1"
    assert [%{"kind" => "computer", "computer_id" => ^machine_id}] = response["targets"]
    refute Enum.any?(response["targets"], &(&1["id"] == "box:#{box.id}"))

    response =
      build_conn()
      |> put_api_token(user, ["box:control"])
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegation-targets")
      |> json_response(200)

    assert [%{"kind" => "box", "id" => "box:" <> _}] = response["targets"]
  end

  test "inventory isolates foreign conversations and target identifiers", %{conn: conn} do
    owner = github_user("unified-owner")
    outsider = github_user("unified-outsider")
    {:ok, conversation} = Conversations.ensure_conversation(owner)
    box = insert_box(conversation.id, "bx-unified-private", "private-box")

    response =
      conn
      |> put_api_token(outsider, ["box:control"])
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegation-targets")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "conversation_not_found"}}

    response =
      build_conn()
      |> put_api_token(owner, ["box:control"])
      |> get(
        ~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{Ecto.UUID.generate()}"
      )
      |> json_response(404)

    assert response == %{"error" => %{"code" => "delegation_not_found"}}
    assert box.label == "private-box"
  end

  test "malformed and unknown delegation identifiers have the missing response", %{conn: conn} do
    user = github_user("unified-identifiers")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    for id <- ["not-an-id", "box:not-an-id", "computer-job:not-an-id"] do
      response =
        conn
        |> put_api_token(user, ["box:control", "computer:control"])
        |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/#{id}")
        |> json_response(404)

      assert response == %{"error" => %{"code" => "delegation_not_found"}}
    end
  end

  test "computer delegation preserves typed policy refusals and redaction", %{conn: conn} do
    user = github_user("unified-computer-policy")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    machine = paired_machine(user, "policy-computer", ["claude"])
    start_supervised!({FakeController, machine_id: machine.id, script: fn _request -> :ok end})

    token_conn = put_api_token(conn, user, ["computer:control"])

    missing_agent =
      token_conn
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "computer:#{machine.id}",
        "agent_id" => "codex",
        "prompt" => "private prompt",
        "cwd" => @root
      })
      |> json_response(422)

    assert missing_agent == %{"error" => %{"code" => "agent_not_available"}}
    refute inspect(missing_agent) =~ "private prompt"

    invalid_cwd =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "computer:#{machine.id}",
        "agent_id" => "claude",
        "prompt" => "private prompt",
        "cwd" => "/tmp/outside"
      })
      |> json_response(422)

    assert invalid_cwd == %{"error" => %{"code" => "cwd_not_allowed"}}
  end

  test "an offline Computer is refused without creating a queued job", %{conn: conn} do
    user = github_user("unified-computer-offline")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    machine = paired_machine(user, "offline-computer", ["codex"])
    before = Repo.aggregate(Work.Job, :count)

    response =
      conn
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "computer:#{machine.id}",
        "agent_id" => "codex",
        "prompt" => "do not queue",
        "cwd" => @root
      })
      |> json_response(409)

    assert response == %{"error" => %{"code" => "computer_offline"}}
    assert Repo.aggregate(Work.Job, :count) == before
  end

  test "human control scopes refuse the opposite target kind", %{conn: conn} do
    user = github_user("unified-scope-independence")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    machine = paired_machine(user, "scope-computer", ["codex"])
    box = insert_box(conversation.id, "bx-unified-scope", "scope-box")

    response =
      conn
      |> put_api_token(user, ["box:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "computer:#{machine.id}",
        "agent_id" => "codex",
        "prompt" => "bounded",
        "cwd" => @root
      })
      |> json_response(403)

    assert response == %{"error" => %{"code" => "insufficient_scope"}}

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "box:#{box.id}",
        "command" => "echo bounded"
      })
      |> json_response(403)

    assert response == %{"error" => %{"code" => "insufficient_scope"}}
  end

  test "delegated grants refuse the opposite target kind", %{conn: conn} do
    user = github_user("unified-delegated-scope")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    machine = paired_machine(user, "delegated-scope-computer", ["codex"])
    box = insert_box(conversation.id, "bx-delegated-scope", "delegated-scope-box")
    run = insert_run(conversation.id, box.id, "completed", "bounded")
    job = insert_job(conversation, machine, "private prompt", "bounded")

    {:ok, box_agent, box_credential} = register_agent("unified-box-only")
    {:ok, box_link} = Agents.request_link(box_agent, user)
    {:ok, _link} = Agents.accept_link(user, box_link.id)
    {:ok, _grant} = Agents.grant_box_control(user, box_agent)

    response =
      conn
      |> bearer(box_credential)
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "computer:#{machine.id}",
        "agent_id" => "codex",
        "prompt" => "must refuse",
        "cwd" => @root
      })
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_computer_control_forbidden"}}

    response =
      build_conn()
      |> bearer(box_credential)
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/computer-job:#{job.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_computer_control_forbidden"}}

    response =
      build_conn()
      |> bearer(box_credential)
      |> delete(~p"/api/v3/conversations/#{conversation.id}/delegations/computer-job:#{job.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_computer_control_forbidden"}}

    {:ok, computer_agent, computer_credential} = register_agent("unified-computer-only")
    {:ok, computer_link} = Agents.request_link(computer_agent, user)
    {:ok, _link} = Agents.accept_link(user, computer_link.id)
    {:ok, _grant} = Agents.grant_computer_control(user, computer_agent)

    response =
      build_conn()
      |> bearer(computer_credential)
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "box:#{box.id}",
        "command" => "must refuse"
      })
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}

    response =
      build_conn()
      |> bearer(computer_credential)
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}

    response =
      build_conn()
      |> bearer(computer_credential)
      |> delete(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}
  end

  test "an unlinked agent cannot start, read, or cancel a delegation", %{conn: conn} do
    user = github_user("unified-unlinked-agent")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx-unified-unlinked", "unlinked-box")
    run = insert_run(conversation.id, box.id, "completed", "bounded")
    {:ok, agent, credential} = register_agent("unified-unlinked")
    {:ok, link} = Agents.request_link(agent, user)
    {:ok, _link} = Agents.accept_link(user, link.id)
    {:ok, _grant} = Agents.grant_box_control(user, agent)
    {:ok, _unlinked} = Agents.unlink(agent, user)

    response =
      conn
      |> bearer(credential)
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "box:#{box.id}",
        "command" => "must refuse"
      })
      |> json_response(404)

    assert response == %{"error" => %{"code" => "target_not_found"}}

    response =
      build_conn()
      |> bearer(credential)
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "delegation_not_found"}}

    response =
      build_conn()
      |> bearer(credential)
      |> delete(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "delegation_not_found"}}
  end

  test "a revoked grant cannot start, read, or cancel a delegation", %{conn: conn} do
    user = github_user("unified-revoked-grant")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx-unified-revoked", "revoked-box")
    run = insert_run(conversation.id, box.id, "completed", "bounded")
    {:ok, agent, credential} = register_agent("unified-revoked")
    {:ok, link} = Agents.request_link(agent, user)
    {:ok, _link} = Agents.accept_link(user, link.id)
    {:ok, _grant} = Agents.grant_box_control(user, agent)
    {:ok, _revoked} = Agents.revoke_box_control(user, agent)

    response =
      conn
      |> bearer(credential)
      |> post(~p"/api/v3/conversations/#{conversation.id}/delegations", %{
        "target_id" => "box:#{box.id}",
        "command" => "must refuse"
      })
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}

    response =
      build_conn()
      |> bearer(credential)
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}

    response =
      build_conn()
      |> bearer(credential)
      |> delete(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(403)

    assert response == %{"error" => %{"code" => "agent_box_control_forbidden"}}
  end

  test "status projects durable Box and Computer records through one envelope", %{conn: conn} do
    user = github_user("unified-status")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx-unified-status", "status-box")

    run =
      insert_run(
        conversation.id,
        box.id,
        "completed",
        "box output https://viewer.ascii.dev/private"
      )

    machine = paired_machine(user, "status-computer", ["codex"])
    job = insert_job(conversation, machine, "private prompt", "private prompt report")

    response =
      conn
      |> put_api_token(user, ["box:control", "computer:control"])
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/box-run:#{run.id}")
      |> json_response(200)

    assert response["delegation"]["kind"] == "box"
    assert response["delegation"]["state"] == "completed"
    assert response["delegation"]["target_id"] == "box:#{box.id}"
    refute inspect(response) =~ "viewer.ascii.dev"

    response =
      build_conn()
      |> put_api_token(user, ["computer:control"])
      |> get(~p"/api/v3/conversations/#{conversation.id}/delegations/computer-job:#{job.id}")
      |> json_response(200)

    assert response["delegation"]["kind"] == "computer"
    assert response["delegation"]["state"] == "completed"
    assert response["delegation"]["output"] == "[redacted] report"
    refute inspect(response) =~ "private prompt"
  end

  defp insert_box(conversation_id, box_id, label) do
    %ConversationBox{}
    |> ConversationBox.changeset(%{
      conversation_id: conversation_id,
      box_id: box_id,
      label: label,
      state: "ready",
      setup_status: "done"
    })
    |> Repo.insert!()
  end

  defp insert_run(conversation_id, conversation_box_id, state, output) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Run{}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: conversation_box_id,
      requesting_principal: %{"type" => "user"},
      command: "echo status",
      idempotency_key: Ecto.UUID.generate(),
      state: state,
      output: output,
      run_directory: "/tmp/openagents/unified-status",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second),
      finished_at: now,
      exit_status: 0
    })
    |> Repo.insert!()
  end

  defp insert_job(conversation, machine, prompt, report) do
    delegation = %{
      "agent_id" => "codex",
      "machine_id" => machine.id,
      "machine_name" => machine.name,
      "prompt" => prompt,
      "timeout_ms" => 3_600_000,
      "cwd" => @root
    }

    {:ok, job} =
      %Job{}
      |> Job.create_changeset(%{
        conversation_id: conversation.id,
        owner_visitor_id: conversation.visitor_id,
        machine_id: machine.id,
        surface: "text",
        kind: "delegation",
        goal: "status",
        delegation: delegation,
        authority_snapshot: %{
          "machine_tier" => machine.tier,
          "roots" => machine.roots,
          "cwd" => @root,
          "agent_id" => "codex",
          "machine_name" => machine.name
        },
        budget_snapshot: %{
          "wall_clock_ms" => 3_600_000,
          "maximum_prompt_bytes" => 8_000,
          "maximum_report_bytes" => 8_000
        }
      })
      |> Repo.insert()

    job =
      job
      |> Job.lifecycle_changeset(%{status: "running", started_at: DateTime.utc_now()})
      |> Repo.update!()

    job
    |> Job.lifecycle_changeset(%{
      status: "completed",
      report: report,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp paired_machine(user, name, agent_ids) do
    {:ok, pairing} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.4.0",
        "roots" => [@root]
      })

    {:ok, machine} = Machines.approve_pairing(user, pairing.code)

    {:ok, machine} =
      Machines.store_probe(machine, %{
        "acp_agents" => Enum.map(agent_ids, &%{"id" => &1, "version" => "1.0"})
      })

    machine
  end

  defp put_api_token(conn, user, scopes) do
    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Unified delegation test", scopes: scopes, lifetime_days: 1})

    put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end

  defp register_agent(handle) do
    Agents.register(%{
      "handle" => handle,
      "display_name" => handle,
      "registration_ip" => "192.0.2.126"
    })
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
