defmodule OpenAgentsWeb.ChatConsoleFleetTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.Box.{ConversationBox, FanoutItem, FanoutRequest, Run}
  alias OpenAgents.Conversations
  alias OpenAgents.Machines
  alias OpenAgents.Repo

  test "renders the durable fleet projection and reconstructs it after reload", %{conn: conn} do
    key = "fleet-console-owner"
    user = github_user(key)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_console_fleet", "box-1")
    insert_run(conversation.id, box.id, "completed", "done https://viewer.ascii.dev/secret")
    insert_queue(conversation.id)

    conn = log_in_admin_user(conn, key)
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-fleet")
    assert has_element?(view, "#chat-console-fleet-cap", "Admitted 1 of 2")
    assert has_element?(view, "#chat-console-fleet-box-#{box.id}", "box-1")
    assert has_element?(view, "#chat-console-fleet-run-state-#{box.id}", "completed")
    assert has_element?(view, "#chat-console-fleet-output-#{box.id}", "done")
    refute render(view) =~ "viewer.ascii.dev"
    assert has_element?(view, "#chat-console-fleet-queue", "admission_pending")
    assert has_element?(view, "#chat-console-fleet-queue article")

    {:ok, reloaded, _html} = live(conn, ~p"/chat")
    assert has_element?(reloaded, "#chat-console-fleet-box-#{box.id}", "box-1")
    assert has_element?(reloaded, "#chat-console-fleet-output-#{box.id}", "done")
    assert has_element?(reloaded, "#chat-console-fleet-queue", "admission_pending")
  end

  test "renders owner controls for an active box and run", %{conn: conn} do
    key = "fleet-console-controls"
    user = github_user(key)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_console_controls", "box-controls")
    run = insert_run(conversation.id, box.id, "running", "")

    conn = log_in_admin_user(conn, key)
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-fleet-stop-#{box.id}")
    assert has_element?(view, "#chat-console-fleet-cancel-#{box.id}")
    assert render(view) =~ ~s(phx-value-box-id="box-controls")
    assert render(view) =~ ~s(phx-value-run-id="#{run.id}")
  end

  test "renders a safe failure when a control targets a missing box", %{conn: conn} do
    key = "fleet-console-refused-control"
    user = github_user(key)
    {:ok, _conversation} = Conversations.ensure_conversation(user)

    conn = log_in_admin_user(conn, key)
    {:ok, view, _html} = live(conn, ~p"/chat")
    refute has_element?(view, "#chat-console-fleet")

    html = render_click(view, "stop_box", %{"box-id" => "missing-box"})

    assert html =~ "That computer is no longer available."
  end

  test "renders paired Computers from the durable projection", %{conn: conn} do
    key = "fleet-console-computer"
    user = github_user(key)
    {:ok, _conversation} = Conversations.ensure_conversation(user)

    {:ok, pairing} =
      Machines.start_pairing(%{
        "name" => "local-coding-computer",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.4.0",
        "roots" => ["/workspace"]
      })

    {:ok, machine} = Machines.approve_pairing(user, pairing.code)

    {:ok, _machine} =
      Machines.store_probe(machine, %{
        "acp_agents" => [%{"id" => "codex", "version" => "1.2.3"}]
      })

    conn = log_in_admin_user(conn, key)
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-fleet")

    assert has_element?(
             view,
             "#chat-console-fleet-computer-#{machine.id}",
             "local-coding-computer"
           )

    assert has_element?(view, "#chat-console-fleet-computer-#{machine.id}", "curated")
    assert render(view) =~ "active"
    refute render(view) =~ "token_digest"
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

  defp insert_run(conversation_id, box_id, state, output) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Run{}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: box_id,
      requesting_principal: %{"type" => "user"},
      command: "echo console",
      idempotency_key: Ecto.UUID.generate(),
      state: state,
      output: output,
      run_directory: "$HOME/.openagents/box-runs/console/#{Ecto.UUID.generate()}",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second),
      finished_at: now,
      exit_status: 0
    })
    |> Repo.insert!()
  end

  defp insert_queue(conversation_id) do
    request =
      %FanoutRequest{}
      |> FanoutRequest.changeset(%{
        conversation_id: conversation_id,
        requesting_principal: %{"type" => "user"},
        requested_count: 1,
        effective_limits: %{"conversation_active_limit" => 2},
        queued_count: 1,
        state: "queued"
      })
      |> Repo.insert!()

    %FanoutItem{}
    |> FanoutItem.changeset(%{
      request_id: request.id,
      conversation_id: conversation_id,
      position: 0,
      label: "box-2",
      requesting_principal: %{"type" => "user"},
      state: "queued",
      queue_reason: "admission_pending",
      estimated_burn_rate_microusd: 100_000
    })
    |> Repo.insert!()
  end
end
