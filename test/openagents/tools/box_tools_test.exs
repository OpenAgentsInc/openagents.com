defmodule OpenAgents.Tools.BoxToolsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Repo
  alias OpenAgents.Tools.{ConversationExecutionContext, Registry, Runner}

  @tools [
    OpenAgents.Tools.BoxNew,
    OpenAgents.Tools.BoxList,
    OpenAgents.Tools.BoxExec,
    OpenAgents.Tools.BoxStop
  ]

  @box_id "bx_8bhkse3n"

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(:openagents, :box_api,
      base_url: "https://box-api.internal",
      poll_interval_ms: 0,
      poll_attempts: 3,
      request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
    )

    Application.put_env(:openagents, :box_api_key, "box_test_credential_value")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    assert {:ok, snapshot} = Registry.build(@tools)

    {:ok, conversation} = Conversations.ensure_conversation("box-tools-test")
    owner = Conversations.get_conversation_owner!(conversation)

    context =
      ConversationExecutionContext.build(%{
        surface: "text",
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        owner_user_id: owner.user_id,
        module_registry_snapshot: snapshot
      })

    %{snapshot: snapshot, context: context, conversation_id: conversation.id}
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp call(name, arguments) do
    %{
      call_id: "call-#{System.unique_integer([:positive])}",
      name: name,
      version: 1,
      raw_arguments: Jason.encode!(arguments)
    }
  end

  defp box_body(overrides \\ %{}) do
    %{
      "box" =>
        Map.merge(
          %{
            "id" => @box_id,
            "state" => "ready",
            "setupStatus" => "done",
            "name" => OpenAgents.Box.provider_ownership_marker()
          },
          overrides
        )
    }
  end

  defp insert_box(conversation_id, box_id, attributes \\ []) do
    %ConversationBox{}
    |> ConversationBox.changeset(
      Enum.into(attributes, %{
        conversation_id: conversation_id,
        box_id: box_id,
        state: "ready",
        setup_status: "done"
      })
    )
    |> Repo.insert!()
  end

  test "box_new provisions a box and returns safe metadata", %{
    snapshot: snapshot,
    context: context
  } do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/boxes"
      Req.Test.json(conn, box_body())
    end)

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, box_body()) end)

    assert {:ok, outcome} = Runner.run(snapshot, call("box_new", %{}), context)
    assert outcome["status"] == "succeeded"
    assert outcome["result"]["box_id"] == @box_id
    assert outcome["result"]["state"] == "ready"
    assert outcome["result"]["setup_status"] == "done"
    assert outcome["target_receipt_refs"] == ["box:#{@box_id}"]
    refute inspect(outcome) =~ "box_test_credential_value"
  end

  test "box_new reports a failed OpenCode setup as a failure", %{
    snapshot: snapshot,
    context: context
  } do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, box_body(%{"setupStatus" => "pending"}))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/boxes/#{@box_id}"
      Req.Test.json(conn, box_body(%{"setupStatus" => "pending"}))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, box_body(%{"setupStatus" => "failed"}))
    end)

    assert {:ok, outcome} = Runner.run(snapshot, call("box_new", %{}), context)
    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "box_setup_failed"
    assert outcome["result"]["box_id"] == @box_id
  end

  test "box_new refuses past the quota with a typed error", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    for index <- 1..OpenAgents.Box.maximum_active_boxes() do
      insert_box(cid, "bx_aaaaaaa#{Enum.at(~w(2 3 4 5 6 7 8 9 a b), index - 1)}")
    end

    assert {:ok, outcome} = Runner.run(snapshot, call("box_new", %{}), context)
    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "box_quota_reached"
  end

  test "box_new fails closed without a Box credential", %{
    snapshot: snapshot,
    context: context
  } do
    Application.delete_env(:openagents, :box_api_key)

    assert {:ok, outcome} = Runner.run(snapshot, call("box_new", %{}), context)
    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "box_not_configured"
    refute inspect(outcome) =~ "box_test_credential_value"
  end

  test "box_list returns only this conversation's boxes", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    {:ok, other} = Conversations.ensure_conversation("box-tools-other")
    insert_box(other.id, "bx_aaaaaaa2")
    insert_box(cid, @box_id, stopped_at: DateTime.utc_now(), state: "archived")

    assert {:ok, outcome} = Runner.run(snapshot, call("box_list", %{}), context)
    assert outcome["status"] == "succeeded"
    assert [box] = outcome["result"]["boxes"]
    assert box["box_id"] == @box_id
    assert box["state"] == "archived"
    assert is_binary(box["stopped_at"])
  end

  test "box_exec runs a command and reports the exit status", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    insert_box(cid, @box_id)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/boxes/#{@box_id}/commands"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert %{"command" => "opencode --version", "timeoutSeconds" => 60} = Jason.decode!(raw)

      Req.Test.json(conn, %{
        "exitCode" => 0,
        "stdout" => "clone https://openagents.com/OpenAgentsInc/openagents.com\n",
        "stderr" => "",
        "timedOut" => false
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("box_exec", %{"command" => "opencode --version", "box_id" => @box_id}),
               context
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["exit_code"] == 0

    assert outcome["result"]["stdout"] ==
             "clone https://openagents.com/OpenAgentsInc/openagents.com\n"

    assert outcome["target_receipt_refs"] == ["box:#{@box_id}"]
  end

  test "box_exec redacts credential-shaped output", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    insert_box(cid, @box_id)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "exitCode" => 0,
        "stdout" =>
          "key is sk-or-v1-abcdefghijklmnop1234 done\n" <>
            "clone https://openagents.com/OpenAgentsInc/openagents.com\n" <>
            "https://viewer.ascii.dev/desktop?access_token=secret\n",
        "stderr" => "",
        "timedOut" => false
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("box_exec", %{"command" => "env", "box_id" => @box_id}),
               context
             )

    refute outcome["result"]["stdout"] =~ "sk-or-v1"
    refute outcome["result"]["stdout"] =~ "viewer.ascii.dev"
    assert outcome["result"]["stdout"] =~ "[REDACTED]"

    assert outcome["result"]["stdout"] =~
             "clone https://openagents.com/OpenAgentsInc/openagents.com"
  end

  test "box_exec reports a timed-out command as failed", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    insert_box(cid, @box_id)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "exitCode" => nil,
        "stdout" => "",
        "stderr" => "",
        "timedOut" => true
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("box_exec", %{
                 "command" => "sleep 999",
                 "box_id" => @box_id,
                 "timeout_seconds" => 1
               }),
               context
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "command_timed_out"
    assert outcome["result"]["timed_out"] == true
  end

  test "box_exec refuses a box this conversation does not own", %{
    snapshot: snapshot,
    context: context
  } do
    {:ok, other} = Conversations.ensure_conversation("box-tools-foreign")
    insert_box(other.id, @box_id)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("box_exec", %{"command" => "id", "box_id" => @box_id}),
               context
             )

    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "box_not_owned"
  end

  test "box_exec rejects an out-of-range timeout", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    insert_box(cid, @box_id)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("box_exec", %{
                 "command" => "id",
                 "box_id" => @box_id,
                 "timeout_seconds" => 601
               }),
               context
             )

    assert outcome["status"] in ["failed", "refused"]
    refute outcome["error"] == nil
  end

  test "box_stop archives the box and frees the slot", %{
    snapshot: snapshot,
    context: context,
    conversation_id: cid
  } do
    insert_box(cid, @box_id)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/boxes/#{@box_id}/stop"
      Req.Test.json(conn, box_body(%{"state" => "archiving"}))
    end)

    assert {:ok, outcome} =
             Runner.run(snapshot, call("box_stop", %{"box_id" => @box_id}), context)

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["state"] == "archiving"
    assert is_binary(outcome["result"]["stopped_at"])

    assert {:ok, refused} =
             Runner.run(snapshot, call("box_stop", %{"box_id" => @box_id}), context)

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "box_stopped"
  end

  test "box tools require the box.control authority", %{snapshot: snapshot, context: context} do
    stripped = %{context | authorities: MapSet.delete(context.authorities, "box.control")}

    for {name, arguments} <- [
          {"box_new", %{}},
          {"box_list", %{}},
          {"box_exec", %{"command" => "id", "box_id" => @box_id}},
          {"box_stop", %{"box_id" => @box_id}}
        ] do
      assert {:ok, outcome} = Runner.run(snapshot, call(name, arguments), stripped)
      assert outcome["status"] == "refused"
      assert outcome["error"]["code"] == "authority_refused"
    end
  end
end
