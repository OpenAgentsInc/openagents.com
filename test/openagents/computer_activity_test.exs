defmodule OpenAgents.ComputerActivityTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.{Accounts, Computer, ComputerActivity, Conversations, Machines}
  alias OpenAgents.Support.FakeController

  # The projection's per-event cap, mirrored here so a drift in the module is
  # a test failure rather than a silent widening. The cumulative cap mirrors
  # the 65,536-byte collection cap and is exercised through the filler chunks
  # below.
  @maximum_event_bytes 16_384

  test "a streamed delegation broadcasts start, bounded chunks, and the typed terminal" do
    %{user: user, conversation: conversation} = owner("computer-live-shape")
    machine = paired_machine(user, "live-box")
    :ok = ComputerActivity.subscribe(conversation.id)

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, "reading the files… ")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-live-1",
        "truncated" => false,
        "duration_ms" => 42
      })
    end)

    task =
      Task.async(fn ->
        Computer.request_agent(
          machine.id,
          %{"agent_id" => "claude", "prompt" => "do the thing", "cwd" => "/home/owner/private"},
          5_000
        )
      end)

    assert_receive {:computer_live_started, started}
    assert started.kind == "agent"
    assert started.machine_id == machine.id
    assert started.machine_name == "live-box"
    assert started.agent_id == "claude"
    assert %DateTime{} = started.started_at

    # The start event is header facts only: never the prompt, cwd, argv, env,
    # or any machine credential.
    assert Map.keys(started) |> Enum.sort() ==
             [:agent_id, :kind, :machine_id, :machine_name, :ref, :started_at]

    ref = started.ref
    assert_receive {:computer_live_chunk, %{ref: ^ref, seq: 1, text: "reading the files… "}}

    assert_receive {:computer_live_terminal, terminal}
    assert terminal == %{ref: ref, status: "completed", stop_reason: "end_turn", duration_ms: 42}

    assert {:ok, %{"status" => "completed"}} = Task.await(task)
  end

  test "chunk broadcasts are capped per event and in total, with one truncation marker" do
    %{user: user, conversation: conversation} = owner("computer-live-caps")
    machine = paired_machine(user, "cap-box")
    :ok = ComputerActivity.subscribe(conversation.id)

    oversized = String.duplicate("a", @maximum_event_bytes + 1_000)
    filler = String.duplicate("b", @maximum_event_bytes)

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, oversized)
      # Three more filler chunks reach the 65,536-byte cumulative cap...
      for _fill <- 1..3, do: FakeController.chunk(caller, request_id, filler)
      # ...so nothing of these ever reaches the socket.
      FakeController.chunk(caller, request_id, "beyond the cap")
      FakeController.chunk(caller, request_id, "still beyond the cap")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "truncated" => true,
        "duration_ms" => 5
      })
    end)

    task =
      Task.async(fn ->
        Computer.request_agent(machine.id, %{"agent_id" => "claude", "prompt" => "go"}, 5_000)
      end)

    assert_receive {:computer_live_started, %{ref: ref}}

    # Per-event cap: the oversized chunk is sliced to the event maximum.
    assert_receive {:computer_live_chunk, %{ref: ^ref, seq: 1, text: first}}
    assert byte_size(first) == @maximum_event_bytes

    for seq <- 2..4 do
      assert_receive {:computer_live_chunk, %{ref: ^ref, seq: ^seq, text: text}}
      assert byte_size(text) <= @maximum_event_bytes
    end

    # Total cap: exactly the mirrored 65,536 bytes were broadcast, then one
    # truncation marker, then no further chunk events — only the terminal.
    assert_receive {:computer_live_truncated, %{ref: ^ref}}
    assert_receive {:computer_live_terminal, %{ref: ^ref, status: "completed"}}
    refute_receive {:computer_live_chunk, _beyond_cap}, 100
    refute_receive {:computer_live_truncated, _second_marker}, 10

    assert {:ok, _result} = Task.await(task)
  end

  test "refusals and timeouts broadcast their typed terminal" do
    %{user: user, conversation: conversation} = owner("computer-live-refused")
    machine = paired_machine(user, "refusing-box")
    :ok = ComputerActivity.subscribe(conversation.id)

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.refused(caller, request_id, "policy_refused", "not on this machine")
    end)

    task =
      Task.async(fn ->
        Computer.request_agent(machine.id, %{"agent_id" => "claude", "prompt" => "go"}, 5_000)
      end)

    assert_receive {:computer_live_started, %{ref: ref}}
    assert_receive {:computer_live_terminal, %{ref: ^ref, status: "refused"}}
    assert {:refused, "policy_refused", _detail} = Task.await(task)
  end

  test "a delegation that never answers broadcasts the timeout terminal" do
    %{user: user, conversation: conversation} = owner("computer-live-timeout")
    machine = paired_machine(user, "silent-box")
    :ok = ComputerActivity.subscribe(conversation.id)

    connect(machine.id, fn {:agent, _request_id, _payload, _caller} -> :ok end)

    task =
      Task.async(fn ->
        Computer.request_agent(machine.id, %{"agent_id" => "claude", "prompt" => "go"}, 50)
      end)

    assert_receive {:computer_live_started, %{ref: ref}}
    assert_receive {:computer_live_terminal, %{ref: ^ref, status: "timeout"}}, 1_000
    assert {:ok, %{"status" => "timeout"}} = Task.await(task)
  end

  test "the projection is scoped to the machine owner's conversation" do
    %{user: user, conversation: _own} = owner("computer-live-owner")
    %{conversation: foreign_conversation} = owner("computer-live-foreign")
    machine = paired_machine(user, "scoped-box")

    # Subscribed to a different conversation's topic: none of this
    # delegation's events may arrive.
    :ok = ComputerActivity.subscribe(foreign_conversation.id)

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, "private progress")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "truncated" => false,
        "duration_ms" => 1
      })
    end)

    task =
      Task.async(fn ->
        Computer.request_agent(machine.id, %{"agent_id" => "claude", "prompt" => "go"}, 5_000)
      end)

    assert {:ok, _result} = Task.await(task)
    refute_receive {:computer_live_started, _foreign}, 100
    refute_receive {:computer_live_chunk, _foreign}, 10
    refute_receive {:computer_live_terminal, _foreign}, 10
  end

  test "an owner without a conversation runs the delegation unprojected" do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "computer-live-no-conversation",
        github_avatar_url: "https://avatars.githubusercontent.com/u/2?v=4"
      })

    machine = paired_machine(user, "unprojected-box")

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, "quiet progress")

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "truncated" => false,
        "duration_ms" => 1
      })
    end)

    assert {:ok, %{"status" => "completed", "output" => "quiet progress"}} =
             Computer.request_agent(
               machine.id,
               %{"agent_id" => "claude", "prompt" => "go"},
               5_000
             )
  end

  defp owner(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    %{user: user, conversation: conversation}
  end

  defp connect(machine_id, script) do
    start_supervised!({FakeController, machine_id: machine_id, script: script})
  end

  defp paired_machine(user, name) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end
end
