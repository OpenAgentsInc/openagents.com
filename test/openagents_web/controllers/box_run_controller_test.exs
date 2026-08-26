defmodule OpenAgentsWeb.BoxRunControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
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

    Application.put_env(:openagents, :box_api_key, "box-run-controller-test")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    :ok
  end

  test "reads a durable run and output from an offset", %{conn: conn} do
    user = github_user("api-token-box-run-controller")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_controller_run",
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
        requesting_principal: %{"type" => "user", "id" => user.id},
        command: "printf hello",
        idempotency_key: "controller-key",
        run_directory: "/tmp/openagents-box-runs/controller",
        state: "completed",
        exit_status: 0,
        output: "hello",
        last_output_offset: 5,
        admitted_at: now,
        started_at: now,
        finished_at: now,
        deadline_at: DateTime.add(now, 60, :second)
      })
      |> Repo.insert!()

    response =
      conn
      |> put_box_api_token("box-run-controller")
      |> get("/api/v1/conversations/#{conversation.id}/boxes/#{box.box_id}/runs/#{run.id}")
      |> json_response(200)

    assert response["run"]["id"] == run.id
    assert response["run"]["state"] == "completed"
    refute Map.has_key?(response["run"], "output")

    output =
      conn
      |> put_box_api_token("box-run-controller")
      |> get(
        "/api/v1/conversations/#{conversation.id}/boxes/#{box.box_id}/runs/#{run.id}/output?offset=2"
      )
      |> json_response(200)

    assert output["output"]["output"] == "llo"
    assert output["output"]["offset"] == 2
    assert output["output"]["next_offset"] == 5
  end

  test "a foreign conversation is indistinguishable from a missing one", %{conn: conn} do
    {:ok, conversation} =
      Conversations.ensure_conversation(github_user("api-token-box-run-owner"))

    {:ok, foreign} = Conversations.ensure_conversation(github_user("box-run-foreign"))

    path =
      "/api/v1/conversations/#{foreign.id}/boxes/bx_foreign/runs/missing/output?offset=0"

    response =
      conn
      |> put_box_api_token("box-run-owner")
      |> get(path)

    assert json_response(response, 404) == %{"error" => %{"code" => "conversation_not_found"}}
    assert conversation.id != foreign.id
  end

  test "idempotency rejects a different command through the API", %{conn: conn} do
    user = github_user("api-token-box-run-idempotency")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_8bhkse3n",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "GET"

      Req.Test.json(request, %{
        "box" => %{"id" => box.box_id, "state" => "ready", "setupStatus" => "done"}
      })
    end)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    path = "/api/v1/conversations/#{conversation.id}/boxes/#{box.box_id}/runs"

    first =
      conn
      |> put_box_api_token("box-run-idempotency")
      |> post(path, %{"command" => "echo one", "idempotency_key" => "same-key"})
      |> json_response(202)

    assert first["run"]["command"] == "echo one"

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "GET"

      Req.Test.json(request, %{
        "box" => %{"id" => box.box_id, "state" => "ready", "setupStatus" => "done"}
      })
    end)

    response =
      conn
      |> put_box_api_token("box-run-idempotency")
      |> post(path, %{"command" => "echo two", "idempotency_key" => "same-key"})

    assert json_response(response, 409) == %{
             "error" => %{"code" => "box_run_idempotency_conflict"}
           }
  end

  test "cancelling a running run answers with the run, not a crash", %{conn: conn} do
    user = github_user("api-token-box-run-cancel")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_8bhkse3n")

    run =
      insert_run(conversation.id, box.id, user.id, "cancel-running", state: "running", pid: 4242)

    worker = start_supervised!({OpenAgents.BoxRunServer, run.id})
    ref = Process.monitor(worker)
    _ = :sys.get_state(worker)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.body_params["command"] =~ "kill"
      Req.Test.json(request, %{"stdout" => "OA_CANCELLED=1\n"})
    end)

    response =
      conn
      |> put_box_api_token("box-run-cancel")
      |> post(
        "/api/v1/conversations/#{conversation.id}/boxes/#{box.box_id}/runs/#{run.id}/cancel"
      )
      |> json_response(202)

    assert response["run"]["id"] == run.id
    assert response["run"]["box_id"] == box.box_id
    assert response["run"]["command"] == "echo worker"
    assert response["run"]["cancellation_requested_at"]

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    assert Repo.get!(Run, run.id).cancellation_requested_at
  end

  test "cancelling an already finished run answers with the run", %{conn: conn} do
    user = github_user("api-token-box-run-cancel-done")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_8bhkse3p")
    run = insert_run(conversation.id, box.id, user.id, "cancel-done", state: "completed")

    response =
      conn
      |> put_box_api_token("box-run-cancel-done")
      |> post(
        "/api/v1/conversations/#{conversation.id}/boxes/#{box.box_id}/runs/#{run.id}/cancel"
      )
      |> json_response(202)

    assert response["run"]["id"] == run.id
    assert response["run"]["box_id"] == box.box_id
    assert response["run"]["state"] == "completed"
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

  defp insert_run(conversation_id, box_pk, user_id, key, options) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    state = Keyword.fetch!(options, :state)

    %Run{id: id}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: box_pk,
      requesting_principal: %{"type" => "user", "id" => user_id},
      command: "echo worker",
      idempotency_key: key,
      state: state,
      pid: Keyword.get(options, :pid),
      run_directory: "$HOME/.openagents/box-runs/users/#{user_id}/#{id}",
      admitted_at: now,
      dispatch_attempted_at: now,
      deadline_at: DateTime.add(now, 60, :second)
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
