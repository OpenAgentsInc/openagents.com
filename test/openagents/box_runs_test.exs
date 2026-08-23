defmodule OpenAgents.BoxRunsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
  alias OpenAgents.BoxRuns
  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(:openagents, :box_api,
      base_url: "https://box-api.internal",
      run_poll_interval_ms: 60_000,
      request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
    )

    Application.put_env(:openagents, :box_api_key, "box-runs-test-key")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    :ok
  end

  test "run states and bounded offset reads are durable" do
    {:ok, conversation} = Conversations.ensure_conversation("box-runs-state")

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_run_state",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    run =
      %Run{}
      |> Run.changeset(%{
        conversation_id: conversation.id,
        conversation_box_id: box.id,
        requesting_principal: %{"type" => "user", "id" => "user"},
        command: "printf hello",
        idempotency_key: "state-key",
        run_directory: "/tmp/openagents-box-runs/state",
        admitted_at: now,
        deadline_at: DateTime.add(now, 60, :second)
      })
      |> Repo.insert!()

    assert {:ok, run} =
             BoxRuns.record_poll(run.id, %{present: true, log_size: 5, output: "hello"})

    assert run.state == "running"
    assert run.last_output_offset == 5

    assert {:ok, run} = BoxRuns.finish(run.id, "completed", 0)
    assert run.state == "completed"
    assert Run.terminal?(run)

    assert {:ok, output} = BoxRuns.read_output(run, 0)
    assert output["output"] == "hello"
    assert output["next_offset"] == 5
    assert output["truncated"] == false
  end

  test "one active run is allowed per box" do
    {:ok, conversation} = Conversations.ensure_conversation("box-runs-lane")

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_run_lane",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      conversation_id: conversation.id,
      conversation_box_id: box.id,
      requesting_principal: %{"type" => "user", "id" => "user"},
      command: "true",
      run_directory: "/tmp/openagents-box-runs/lane",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second)
    }

    assert {:ok, _run} =
             %Run{}
             |> Run.changeset(Map.put(attrs, :idempotency_key, "lane-one"))
             |> Repo.insert()

    assert {:error, changeset} =
             %Run{}
             |> Run.changeset(Map.put(attrs, :idempotency_key, "lane-two"))
             |> Repo.insert()

    assert %{conversation_box_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "every terminal state is durable" do
    {:ok, conversation} = Conversations.ensure_conversation("box-runs-terminal")

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_run_terminal",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    for state <- Run.terminal_states() do
      run = insert_run(conversation.id, box.id, "terminal-#{state}")
      exit_status = if state == "failed", do: 17
      reason = if state in ["lost", "timed_out"], do: "test_reason"

      assert {:ok, finished} = BoxRuns.finish(run.id, state, exit_status, reason)
      assert finished.state == state
      assert Run.terminal?(finished)
      assert finished.finished_at
      assert finished.timed_out == (state == "timed_out")
    end
  end

  test "poll output is bounded, redacted, and does not duplicate" do
    {:ok, conversation} = Conversations.ensure_conversation("box-runs-output")

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_run_output",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    run = insert_run(conversation.id, box.id, "output-key")
    payload = String.duplicate("x", 30_000) <> " https://openagents.com/clone"

    assert {:ok, first} =
             BoxRuns.record_poll(run.id, %{
               present: true,
               log_size: byte_size(payload),
               output: payload
             })

    assert {:ok, second} =
             BoxRuns.record_poll(run.id, %{
               present: true,
               log_size: byte_size(payload),
               output: payload
             })

    assert second.output == first.output
    assert byte_size(second.output) <= 24 * 1_024
    assert second.output =~ "https://openagents.com/clone"
    assert second.last_output_offset == byte_size(payload)
  end

  test "worker drives a detached run to completed" do
    run = insert_worker_run("worker-completed", state: "admitted")

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/bx_8bhkse3n/commands"
      assert request.body_params["command"] =~ run.run_directory
      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "OA_EXIT"

      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=0\nOA_DATA=\nOA_EXIT=0\nOA_ALIVE=0\n"
      })
    end)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert Repo.get!(Run, run.id).state == "completed"
  end

  test "worker records a nonzero exit as failed" do
    run = insert_worker_run("worker-failed", state: "admitted")

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "OA_EXIT"

      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=0\nOA_DATA=\nOA_EXIT=17\nOA_ALIVE=0\n"
      })
    end)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    failed = Repo.get!(Run, run.id)
    assert failed.state == "failed"
    assert failed.exit_status == 17
  end

  test "ambiguous dispatch probes once and becomes lost without redispatch" do
    run = insert_worker_run("worker-ambiguous", state: "admitted")

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "mkdir"
      Req.Test.transport_error(request, :econnrefused)
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "OA_PRESENT"
      Req.Test.json(request, %{"stdout" => "OA_PRESENT=0\n"})
    end)

    {pid, ref} = start_worker(run.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    lost = Repo.get!(Run, run.id)
    assert lost.state == "lost"
    assert lost.failure_reason == "dispatch_ambiguous"
  end

  test "a present directory after ambiguous dispatch recovers without a fake pid" do
    run = insert_worker_run("worker-probe", state: "admitted")

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.transport_error(request, :closed)
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "OA_PID"
      Req.Test.json(request, %{"stdout" => "OA_PRESENT=1\n"})
    end)

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=0\nOA_DATA=\nOA_ALIVE=1\n"
      })
    end)

    {pid, _ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    _ = :sys.get_state(pid)

    recovered = Repo.get!(Run, run.id)
    assert recovered.state == "running"
    assert recovered.pid == nil
  end

  test "cancellation retries the kill and remains terminal on later read" do
    run = insert_worker_run("worker-cancel", state: "running", pid: 4242)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)

    assert {:ok, requested} = BoxRuns.cancel(run)
    assert requested.cancellation_requested_at

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "forge-credential"
      assert request.body_params["command"] =~ "gitconfig"
      Req.Test.transport_error(request, :econnrefused)
    end)

    _ = :sys.get_state(pid)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "kill"
      assert request.body_params["command"] =~ "rm -f"
      assert request.body_params["command"] =~ "forge-credential"
      assert request.body_params["command"] =~ "gitconfig"
      Req.Test.json(request, %{"stdout" => "OA_CANCELLED=1\n"})
    end)

    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    cancelled = Repo.get!(Run, run.id)
    assert cancelled.state == "cancelled"
    assert cancelled.cancellation_requested_at
    assert cancelled.cancellation_effective_at

    assert DateTime.compare(
             cancelled.cancellation_effective_at,
             cancelled.cancellation_requested_at
           ) in [:eq, :gt]

    assert {:ok, later} = BoxRuns.get_run(run.conversation_id, "bx_8bhkse3n", run.id)
    assert later.state == "cancelled"
  end

  test "deadline expiration kills the run and reaches timed out" do
    run = insert_worker_run("worker-timeout", state: "running", pid: 4343, deadline_at: past())

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "kill"
      assert request.body_params["command"] =~ "rm -f"
      assert request.body_params["command"] =~ "forge-credential"
      assert request.body_params["command"] =~ "gitconfig"
      Req.Test.json(request, %{"stdout" => "OA_CANCELLED=1\n"})
    end)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    timed_out = Repo.get!(Run, run.id)
    assert timed_out.state == "timed_out"
    assert timed_out.timed_out
  end

  test "a missing run directory becomes lost with a reason" do
    run = insert_worker_run("worker-missing", state: "running", pid: 4444)

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{"stdout" => "OA_PRESENT=0\n"})
    end)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    lost = Repo.get!(Run, run.id)
    assert lost.state == "lost"
    assert lost.failure_reason == "run_directory_missing"
  end

  test "a stopped box becomes lost with the provider reason" do
    run = insert_worker_run("worker-stopped", state: "running", pid: 4646)

    Req.Test.expect(__MODULE__, fn request ->
      request
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{"code" => "box_stopped"})
    end)

    {pid, ref} = start_worker(run.id)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    lost = Repo.get!(Run, run.id)
    assert lost.state == "lost"
    assert lost.failure_reason == "box_stopped"
  end

  test "startup reconciliation restarts a persisted nonterminal run" do
    run = insert_worker_run("worker-recovery", state: "running", pid: 4545)

    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=0\nOA_DATA=\nOA_EXIT=0\nOA_ALIVE=0\n"
      })
    end)

    assert :ok = BoxRuns.reconcile_non_terminal()
    assert [{pid, _}] = Registry.lookup(OpenAgents.BoxRunRegistry, run.id)
    ref = Process.monitor(pid)
    _ = :sys.get_state(pid)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert Repo.get!(Run, run.id).state == "completed"
  end

  test "idempotency conflicts refuse a different command" do
    {:ok, conversation} = Conversations.ensure_conversation("worker-idempotency")
    insert_box(conversation.id, "bx_8bhkse3n")

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "GET"

      Req.Test.json(request, %{
        "box" => %{"id" => "bx_8bhkse3n", "state" => "ready", "setupStatus" => "done"}
      })
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "mkdir"
      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    assert {:ok, first} =
             BoxRuns.start_run(
               conversation.id,
               "bx_8bhkse3n",
               %{"type" => "user", "id" => "worker-idempotency"},
               "echo one",
               "same-key"
             )

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "GET"

      Req.Test.json(request, %{
        "box" => %{"id" => "bx_8bhkse3n", "state" => "ready", "setupStatus" => "done"}
      })
    end)

    assert {:error, :box_run_idempotency_conflict} =
             BoxRuns.start_run(
               conversation.id,
               "bx_8bhkse3n",
               %{"type" => "user", "id" => "worker-idempotency"},
               "echo two",
               "same-key"
             )

    assert Repo.aggregate(Run, :count, :id) == 1
    assert first.command == "echo one"
  end

  defp insert_run(conversation_id, conversation_box_id, idempotency_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Run{}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: conversation_box_id,
      requesting_principal: %{"type" => "user", "id" => "user"},
      command: "true",
      idempotency_key: idempotency_key,
      run_directory: "/tmp/openagents-box-runs/#{Ecto.UUID.generate()}",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second)
    })
    |> Repo.insert!()
  end

  defp insert_worker_run(key, options) do
    {:ok, conversation} = Conversations.ensure_conversation("worker-" <> key)
    box = insert_box(conversation.id, "bx_8bhkse3n")
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    state = Keyword.get(options, :state, "running")

    %Run{id: id}
    |> Run.changeset(%{
      conversation_id: conversation.id,
      conversation_box_id: box.id,
      requesting_principal: %{"type" => "user", "id" => key},
      command: "echo worker",
      idempotency_key: key,
      state: state,
      pid: Keyword.get(options, :pid),
      run_directory: "$HOME/.openagents/box-runs/users/#{key}/#{id}",
      admitted_at: now,
      deadline_at: Keyword.get(options, :deadline_at, DateTime.add(now, 60, :second)),
      dispatch_attempted_at: if(state == "admitted", do: nil, else: now)
    })
    |> Repo.insert!()
    |> Repo.preload(:conversation_box)
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

  defp start_worker(run_id) do
    pid = start_supervised!({OpenAgents.BoxRunServer, run_id})
    {pid, Process.monitor(pid)}
  end

  defp past do
    DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
