defmodule OpenAgents.Memory.SemanticWorkerTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Memory.{SemanticIndex, SemanticJob, SemanticWorker}

  @provider OpenAgents.Memory.SemanticWorkerTestProvider

  setup do
    original_config = Application.fetch_env!(:openagents, :semantic_index)
    original_mode = Application.get_env(:openagents, :semantic_worker_test_mode)

    Application.put_env(:openagents, :semantic_index,
      enabled: true,
      provider: @provider,
      model_id: "semantic-worker-test",
      model_version: "v1",
      dimensions: 64,
      batch_size: 20,
      poll_interval_ms: 60_000,
      provider_timeout_ms: 5_000,
      lease_ms: 10_000
    )

    on_exit(fn ->
      Application.put_env(:openagents, :semantic_index, original_config)

      if is_nil(original_mode),
        do: Application.delete_env(:openagents, :semantic_worker_test_mode),
        else: Application.put_env(:openagents, :semantic_worker_test_mode, original_mode)
    end)

    :ok
  end

  test "provider failure becomes a bounded durable failure without killing the worker" do
    Application.put_env(:openagents, :semantic_worker_test_mode, :failure)
    worker = start_worker(:semantic_failure_worker)
    assert {:ok, _conversation} = Conversations.ensure_conversation("semantic-worker-failure")

    assert {:ok, %{completed: 0, failed: 1, invalidated: 0}} =
             SemanticWorker.drain(worker)

    assert %SemanticJob{status: "failed", error_code: "semantic_provider_offline", attempts: 1} =
             Repo.one!(SemanticJob)

    _state = :sys.get_state(worker)
  end

  test "a drain exception is contained so a later database pass can succeed" do
    Application.put_env(:openagents, :semantic_worker_test_mode, :success)
    attempts = start_supervised!({Agent, fn -> 0 end})

    processor = fn _config ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> raise "database unavailable"
        _later -> %{completed: 0, failed: 0, invalidated: 0}
      end
    end

    worker = start_worker(:semantic_database_worker, processor: processor)

    assert {:error, :semantic_drain_failed} = SemanticWorker.drain(worker)
    assert {:ok, %{completed: 0, failed: 0, invalidated: 0}} = SemanticWorker.drain(worker)
    _state = :sys.get_state(worker)
  end

  test "an expired running lease is reclaimed after the worker process dies" do
    Application.put_env(:openagents, :semantic_worker_test_mode, {:block, self()})
    assert {:ok, _conversation} = Conversations.ensure_conversation("semantic-worker-reclaim")
    first = start_worker(:semantic_crash_worker)

    {caller, caller_ref} =
      spawn_monitor(fn ->
        SemanticWorker.drain(first)
      end)

    assert_receive {:semantic_provider_started, provider_task}
    assert %SemanticJob{status: "running", attempts: 1} = Repo.one!(SemanticJob)

    Repo.update_all(SemanticJob,
      set: [available_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    provider_ref = Process.monitor(provider_task)
    worker_ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^first, :killed}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, _reason}
    send(provider_task, :release_semantic_provider)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider_task, _reason}, 1_000

    Application.put_env(:openagents, :semantic_worker_test_mode, :success)
    second = start_worker(:semantic_replacement_worker)

    assert {:ok, %{completed: 1, failed: 0, invalidated: 0}} =
             SemanticWorker.drain(second)

    assert %SemanticJob{status: "completed", attempts: 2, error_code: nil} =
             Repo.one!(SemanticJob)

    assert embedding_count() == 1
  end

  test "a reclaimed attempt fences the first provider result" do
    Application.put_env(:openagents, :semantic_worker_test_mode, {:block, self()})
    config = Application.fetch_env!(:openagents, :semantic_index) |> Map.new()
    _manifest = SemanticIndex.ensure_manifest!(config)
    assert {:ok, _conversation} = Conversations.ensure_conversation("semantic-attempt-fence")
    observer = self()

    first =
      start_supervised!(
        {Task,
         fn ->
           result =
             SemanticIndex.process_next(@provider,
               provider_timeout_ms: 30_000,
               lease_ms: 30_000
             )

           send(observer, {:first_semantic_result, result})
         end}
      )

    assert_receive {:semantic_provider_started, provider_task}
    assert %SemanticJob{status: "running", attempts: 1} = Repo.one!(SemanticJob)

    Repo.update_all(SemanticJob,
      set: [available_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    Application.put_env(:openagents, :semantic_worker_test_mode, :success)

    assert {:ok, :completed} =
             SemanticIndex.process_next(@provider,
               provider_timeout_ms: 5_000,
               lease_ms: 10_000
             )

    first_ref = Process.monitor(first)
    send(provider_task, :release_semantic_provider)
    assert_receive {:first_semantic_result, {:ok, :invalidated}}
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}

    assert %SemanticJob{status: "completed", attempts: 2} = Repo.one!(SemanticJob)
    assert embedding_count() == 1
  end

  defp start_worker(id, options \\ []) do
    name = Module.concat(__MODULE__, id)

    spec =
      Supervisor.child_spec(
        {SemanticWorker, Keyword.merge([name: name, autostart: false], options)},
        id: id,
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp embedding_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM message_semantic_embeddings")
    count
  end
end
