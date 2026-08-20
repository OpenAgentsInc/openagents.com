defmodule OpenAgents.TurnToolLoopTest do
  use OpenAgents.DataCase
  import Ecto.Query

  alias OpenAgents.{Conversations, Turns}

  setup do
    Application.put_env(:openagents, :test_tool_observer, self())
    on_exit(fn -> Application.delete_env(:openagents, :test_tool_observer) end)
    :ok
  end

  test "a committed tool outcome continues under the same call ID and completes text" do
    turn = start_and_wait("successful-tool-loop", "[tool-loop]")

    assert turn.status == "completed"
    assert_receive {:test_tool_executed, _tool_pid, "quartz", scope_ref}
    assert scope_ref == "conversation:#{turn.conversation_id}"

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.status == "completed"

    assert receipt.profile_memory_snapshot_ref =~
             ~r/^profile-memory-snapshot:v1:[0-9a-f-]{36}$/

    assert receipt.preference_snapshot_ref =~
             ~r/^preference-snapshot:v1:[0-9a-f-]{36}$/

    assert receipt.used_preferences == %{
             "schema" => "sarah.preference_usage.v1",
             "applied" => [],
             "overridden" => []
           }

    assert receipt.used_source_refs == ["message:test-match"]

    assert [step] = tool_steps(turn)
    assert step.status == "succeeded"
    assert step.provider_call_id == "call-tool-1"
    assert step.raw_arguments == ~s({"query":"quartz"})
    assert step.argument_digest == OpenAgents.Provenance.Canonical.digest!(%{"query" => "quartz"})
    assert step.result == %{"matches" => ["Found quartz in this conversation."]}
    assert receipt.used_tool_step_refs == ["tool-step:#{step.id}"]

    assert [route] = route_receipts(receipt)
    assert route.status == "selected"
    assert route.intent_digest == receipt.input_digest
    assert route.registry_digest == receipt.tool_catalog_digest
    assert route.selected["module_id"] == step.module_id
    assert route.proposed["artifact_digest"] == step.module_artifact_digest
    refute inspect(route) =~ "[tool-loop]"

    assert [first_provider, final_provider] = Conversations.list_provider_steps(receipt)
    assert first_provider.provider_response_id == "tool-loop-0"
    assert final_provider.provider_response_id == "tool-loop-final"

    assistant = OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)
    assert assistant.content == "Known tool outcome: succeeded."
  end

  test "tool argument content stays out of operational logs while the step retains it" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        turn = start_and_wait("log-redaction-tool-loop", "[tool-loop]")
        assert turn.status == "completed"

        assert [step] = tool_steps(turn)
        assert step.raw_arguments == ~s({"query":"quartz"})
      end)

    refute log =~ "quartz"
  end

  test "unknown and invalid calls never reach an executor and wording follows durable status" do
    unknown = start_and_wait("unknown-tool-loop", "[unknown-tool-loop]")
    invalid = start_and_wait("invalid-tool-loop", "[invalid-tool-loop]")

    refute_receive {:test_tool_executed, _pid, _query, _scope_ref}, 50

    [unknown_step] = tool_steps(unknown)
    [invalid_step] = tool_steps(invalid)
    assert unknown_step.status == "unavailable"
    assert unknown_step.error["code"] == "module_route_unavailable"
    assert invalid_step.status == "failed"
    assert invalid_step.error["code"] == "required_property_missing"

    assert {:ok, unknown_receipt} = Conversations.get_turn_receipt(unknown)
    assert [unknown_route] = route_receipts(unknown_receipt)
    assert unknown_route.status == "unavailable"
    assert unknown_route.selected == nil

    assert {:ok, invalid_receipt} = Conversations.get_turn_receipt(invalid)
    assert [invalid_route] = route_receipts(invalid_receipt)
    assert invalid_route.status == "selected"

    unknown_message =
      OpenAgents.Repo.get!(OpenAgents.Conversations.Message, unknown.assistant_message_id)

    invalid_message =
      OpenAgents.Repo.get!(OpenAgents.Conversations.Message, invalid.assistant_message_id)

    assert unknown_message.content == "Unknown tool outcome: unavailable."
    assert invalid_message.content == "Invalid call outcome: failed."
  end

  test "the execution ceiling refuses the next call and completes the turn with a report" do
    turn = start_and_wait("continuation-limit-loop", "[continuation-limit]")

    assert turn.status == "completed"

    for index <- 0..15 do
      assert_receive {:test_tool_executed, _pid, query, _scope_ref}
      assert query == "q#{index}"
    end

    refute_receive {:test_tool_executed, _pid, "q16", _scope_ref}, 50

    steps = tool_steps(turn)
    assert length(steps) == 17

    {completed, [limited]} = Enum.split(steps, 16)
    assert Enum.all?(completed, &(&1.status == "succeeded"))
    assert limited.status == "failed"
    assert limited.error["code"] == "tool_call_limit_reached"

    message = OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)
    assert message.content == "Limit report outcome: failed."
  end

  test "user cancellation reaches active tool work and persists cancellation" do
    %{turn: queued_turn} = create_turn("cancel-active-tool", "[cancel-tool-loop]")
    assert {:ok, pid} = Turns.start(queued_turn.id)
    monitor = Process.monitor(pid)

    assert_receive {:test_tool_executed, _tool_pid, "block", _scope_ref}, 1_000
    assert {:ok, cancelled_turn} = Turns.cancel(queued_turn.id)
    assert cancelled_turn.status == "cancelled"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    [step] = tool_steps(cancelled_turn)
    assert step.status == "cancelled"
    assert step.error["code"] == "cancelled"
  end

  test "restart recovery preserves the multi-step chain and interrupts active tool work" do
    %{turn: queued_turn} = create_turn("restart-active-tool", "[cancel-tool-loop]")
    assert {:ok, pid} = Turns.start(queued_turn.id)
    monitor = Process.monitor(pid)

    assert_receive {:test_tool_executed, tool_pid, "block", _scope_ref}, 1_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert :ok = Conversations.recover_interrupted_turns()
    send(tool_pid, :release_test_tool)

    recovered_turn = Conversations.get_turn!(queued_turn.id)
    assert recovered_turn.status == "failed"

    assert {:ok, receipt} = Conversations.get_turn_receipt(recovered_turn)
    assert receipt.status == "interrupted"
    assert length(Conversations.list_provider_steps(receipt)) == 1

    [step] = tool_steps(recovered_turn)
    assert step.status == "interrupted"
    assert step.error["code"] == "runtime_restarted"
  end

  test "search then read grounds a final answer and records materially used source refs" do
    browser_key = "end-to-end-recall-tool-loop"
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)

    source =
      OpenAgents.Repo.insert!(%OpenAgents.Conversations.Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Please remember the exact marker violet-cascade-42 for later.",
        status: "complete",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

    turn = start_and_wait(browser_key, "[recall-tool-loop]")
    assert turn.status == "completed"

    assert [search, read] = tool_steps(turn)
    assert search.tool_name == "conversation_search"
    assert search.status == "succeeded"
    assert read.tool_name == "conversation_read"
    assert read.status == "succeeded"

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.memory_snapshot_ref =~ ~r/^message:/
    assert "message:#{source.id}" in receipt.used_source_refs
    assert length(receipt.used_tool_step_refs) == 2

    assert receipt.used_memory_evidence == %{
             "schema" => "sarah.memory_evidence_usage.v1",
             "items" => [
               %{
                 "source_ref" => "message:#{source.id}",
                 "classification" => "applicable"
               }
             ]
           }

    assert length(Conversations.list_provider_steps(receipt)) == 3

    assistant = OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)

    assert assistant.content ==
             "On #{Date.to_iso8601(DateTime.to_date(source.inserted_at))}, you called the marker violet-cascade-42."
  end

  test "lexical degradation completes honestly and persists the typed failed step" do
    original_backend = Application.fetch_env!(:openagents, :recall_search_backend)

    Application.put_env(
      :openagents,
      :recall_search_backend,
      OpenAgents.Memory.UnavailableRecallBackend
    )

    on_exit(fn -> Application.put_env(:openagents, :recall_search_backend, original_backend) end)

    turn = start_and_wait("recall-unavailable-browser", "[recall-unavailable]")
    assert turn.status == "completed"

    [step] = tool_steps(turn)
    assert step.tool_name == "conversation_search"
    assert step.status == "failed"
    assert step.error["code"] == "lexical_unavailable"
    assert step.target_receipt_refs == []

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.used_source_refs == []
    assert receipt.used_memory_evidence["items"] == []

    assistant = OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)

    assert assistant.content ==
             "I couldn't search older messages just now, so I can't verify that history."
  end

  test "provider continuation failure preserves recall evidence and fails the turn" do
    browser_key = "recall-continuation-failure-browser"
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)

    OpenAgents.Repo.insert!(%OpenAgents.Conversations.Message{
      conversation_id: conversation.id,
      role: "user",
      content: "The continuation marker is continuation-anchor-90.",
      status: "complete"
    })

    turn = start_and_wait(browser_key, "[recall-continuation-failure]")
    assert turn.status == "failed"
    assert [step] = tool_steps(turn)
    assert step.status == "succeeded"
    assert step.target_receipt_refs != []

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.status == "failed"
    assert length(Conversations.list_provider_steps(receipt)) == 2
  end

  test "a foreign source ID is indistinguishable from an unknown ID through the turn loop" do
    assert {:ok, foreign} = Conversations.ensure_conversation("turn-loop-foreign-source")

    source =
      OpenAgents.Repo.insert!(%OpenAgents.Conversations.Message{
        conversation_id: foreign.id,
        role: "user",
        content: "Private source that must not cross browser scope.",
        status: "complete"
      })

    Application.put_env(:openagents, :test_foreign_source_ref, "message:#{source.id}")
    on_exit(fn -> Application.delete_env(:openagents, :test_foreign_source_ref) end)

    turn = start_and_wait("turn-loop-local-source", "[foreign-source-read]")
    assert turn.status == "completed"
    assert [step] = tool_steps(turn)
    assert step.status == "failed"
    assert step.error["code"] == "not_found"
    assert step.target_receipt_refs == []

    assistant = OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)
    assert assistant.content == "Recall source outcome: failed."
  end

  test "remember, list, and forget complete as durable end-to-end tool journeys" do
    browser_key = "profile-memory-end-to-end"

    remembered = start_and_wait(browser_key, "Remember that I prefer concise answers")
    assert remembered.status == "completed"
    assert [remember_step] = tool_steps(remembered)
    assert remember_step.tool_name == "memory_remember"
    assert remember_step.status == "succeeded"
    assert get_in(remember_step.result, ["receipt", "disposition"]) == "stored"

    listed = start_and_wait(browser_key, "What do you remember about me?")
    assert listed.status == "completed"
    assert [list_step] = tool_steps(listed)
    assert list_step.tool_name == "memory_list"

    assert get_in(list_step.result, ["memories", Access.at(0), "claim"]) ==
             "I prefer concise answers"

    forgotten = start_and_wait(browser_key, "Forget that I prefer concise answers")
    assert forgotten.status == "completed"
    assert [forget_list_step, forget_write_step] = tool_steps(forgotten)
    assert forget_list_step.tool_name == "memory_list"
    assert forget_write_step.tool_name == "memory_forget"
    assert get_in(forget_write_step.result, ["receipt", "disposition"]) == "forgotten"

    conversation = Conversations.get_conversation_for_browser(browser_key)
    owner = OpenAgents.Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    assert {:ok, []} = OpenAgents.ProfileMemory.list_current(owner)

    assistant =
      OpenAgents.Repo.get!(OpenAgents.Conversations.Message, forgotten.assistant_message_id)

    assert assistant.content == "I forgot that profile memory in this browser."
  end

  defp start_and_wait(browser_key, prompt) do
    %{turn: turn} = create_turn(browser_key, prompt)
    assert {:ok, pid} = Turns.start(turn.id)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
    Conversations.get_turn!(turn.id)
  end

  defp create_turn(browser_key, prompt) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, prompt)
    records
  end

  defp tool_steps(turn) do
    OpenAgents.Repo.all(
      from(step in OpenAgents.Conversations.ToolStep,
        where: step.turn_id == ^turn.id,
        order_by: [asc: step.sequence]
      )
    )
  end

  defp route_receipts(receipt) do
    OpenAgents.Repo.all(
      from(route in OpenAgents.Modules.RouteReceipt,
        where: route.turn_receipt_id == ^receipt.id,
        order_by: [asc: route.inserted_at]
      )
    )
  end
end
