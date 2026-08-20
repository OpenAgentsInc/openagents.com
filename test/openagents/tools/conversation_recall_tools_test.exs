defmodule OpenAgents.Tools.ConversationRecallToolsTest do
  use OpenAgents.SarahDataCase

  alias OpenAgents.{Context.Composer, Conversations, Repo, Voice}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Providers.Request
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.Voice.Config, as: VoiceConfig
  alias OpenAgents.Voice.ResponseReceipt, as: VoiceResponseReceipt
  alias OpenAgents.Voice.ToolStep, as: VoiceToolStep

  setup do
    original_backend = Application.fetch_env!(:openagents, :recall_search_backend)

    on_exit(fn ->
      Application.put_env(:openagents, :recall_search_backend, original_backend)
      Application.delete_env(:openagents, :test_recall_backend_observer)
    end)

    :ok
  end

  test "provider schemas expose optional bounds without weakening host validation" do
    definitions =
      Registry.current!() |> Registry.provider_definitions() |> Map.new(&{&1.name, &1})

    refute definitions["conversation_search"].strict
    refute definitions["conversation_read"].strict
    assert definitions["recall_messages"].strict
  end

  test "search discovery followed by read returns exact bounded source context" do
    {:ok, conversation} = Conversations.ensure_conversation("recall-tools-browser")
    base = DateTime.utc_now() |> DateTime.add(-120, :second)
    before = insert_message(conversation.id, "user", "Context before the marker.", base)

    target =
      insert_message(
        conversation.id,
        "assistant",
        "The exact historical marker is amber-orbit-71.",
        DateTime.add(base, 1, :second)
      )

    after_message =
      insert_message(
        conversation.id,
        "user",
        "Context after the marker.",
        DateTime.add(base, 2, :second)
      )

    %{receipt: receipt} = begin_inference(conversation, "What was the amber marker?")
    context = execution_context(conversation, receipt)

    search = run_tool("conversation_search", ~s({"query":"amber-orbit-71","first":3}), context)
    assert search["status"] == "succeeded"
    assert search["result"]["schema"] == "sarah.conversation_search_result.v1"
    assert search["result"]["status"] == "matches"
    assert search["result"]["snapshot_ref"] == receipt.memory_snapshot_ref
    assert [%{"source_ref" => source_ref, "rank" => 1}] = search["result"]["matches"]
    assert source_ref == "message:#{target.id}"
    assert search["target_receipt_refs"] == [source_ref]

    read =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => source_ref, "before" => 1, "after" => 1}),
        context
      )

    assert read["status"] == "succeeded"
    assert read["result"]["schema"] == "sarah.conversation_read_result.v1"
    assert read["result"]["source_ref"] == source_ref
    assert read["result"]["evidence"]["source_ref"] == source_ref
    assert read["result"]["evidence"]["classification"] == "applicable"

    assert read["result"]["evidence"]["claim"] ==
             "The exact historical marker is amber-orbit-71."

    assert Enum.map(read["result"]["messages"], & &1["source_ref"]) == [
             "message:#{before.id}",
             "message:#{target.id}",
             "message:#{after_message.id}"
           ]

    assert Enum.at(read["result"]["messages"], 1)["content"] ==
             "The exact historical marker is amber-orbit-71."
  end

  test "foreign and unknown source refs have the same safe not-found outcome" do
    {:ok, first} = Conversations.ensure_conversation("recall-tools-first-browser")
    {:ok, second} = Conversations.ensure_conversation("recall-tools-second-browser")
    foreign = insert_message(first.id, "user", "Private foreign marker.", DateTime.utc_now())
    %{receipt: second_receipt} = begin_inference(second, "Read a source.")
    context = execution_context(second, second_receipt)

    foreign_outcome =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "message:#{foreign.id}"}),
        context
      )

    unknown_outcome =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "message:#{Ecto.UUID.generate()}"}),
        context
      )

    assert foreign_outcome["status"] == "failed"
    assert foreign_outcome["error"]["code"] == "not_found"
    assert unknown_outcome["status"] == "failed"
    assert unknown_outcome["error"] == foreign_outcome["error"]

    wrong_host_context = %{
      context
      | conversation_id: first.id,
        scope_ref: "conversation:#{second.id}"
    }

    refused = run_tool("conversation_search", ~s({"query":"marker"}), wrong_host_context)
    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "scope_refused"
  end

  test "search and read expose empty, invalid, and truncation outcomes" do
    {:ok, conversation} = Conversations.ensure_conversation("recall-tools-bounds-browser")
    base = DateTime.utc_now() |> DateTime.add(-180, :second)

    messages =
      for index <- 0..6 do
        insert_message(
          conversation.id,
          if(rem(index, 2) == 0, do: "user", else: "assistant"),
          "bounded constellation #{index}",
          DateTime.add(base, index, :second)
        )
      end

    %{receipt: receipt} = begin_inference(conversation, "Inspect bounded context.")
    context = execution_context(conversation, receipt)

    empty = run_tool("conversation_search", ~s({"query":"does-not-exist"}), context)
    assert empty["status"] == "succeeded"
    assert empty["result"]["status"] == "empty"
    assert empty["result"]["matches"] == []

    truncated =
      run_tool("conversation_search", ~s({"query":"constellation","first":2}), context)

    assert truncated["status"] == "succeeded"
    assert length(truncated["result"]["matches"]) == 2
    assert truncated["result"]["truncated"]

    source = Enum.at(messages, 3)

    read =
      run_tool(
        "conversation_read",
        Jason.encode!(%{
          "source_ref" => "message:#{source.id}",
          "before" => 1,
          "after" => 1
        }),
        context
      )

    assert read["status"] == "succeeded"
    assert read["result"]["before_truncated"]
    assert read["result"]["after_truncated"]
    assert length(read["result"]["messages"]) == 3

    invalid_limit =
      run_tool("conversation_search", ~s({"query":"constellation","first":11}), context)

    assert invalid_limit["status"] == "failed"
    assert invalid_limit["error"]["code"] == "invalid_result_limit"

    invalid_time =
      run_tool("conversation_search", ~s({"query":"constellation","before":"later"}), context)

    assert invalid_time["status"] == "failed"
    assert invalid_time["error"]["code"] == "invalid_time_bound"
  end

  test "lexical unavailability, timeout, and cancellation remain typed outcomes" do
    {:ok, conversation} = Conversations.ensure_conversation("recall-tools-degradation-browser")
    %{receipt: receipt} = begin_inference(conversation, "Inspect unavailable history.")
    context = execution_context(conversation, receipt)

    Application.put_env(
      :openagents,
      :recall_search_backend,
      OpenAgents.Memory.UnavailableRecallBackend
    )

    unavailable = run_tool("conversation_search", ~s({"query":"history"}), context)
    assert unavailable["status"] == "failed"
    assert unavailable["error"]["code"] == "lexical_unavailable"

    Application.put_env(
      :openagents,
      :recall_search_backend,
      OpenAgents.Memory.BlockingRecallBackend
    )

    Application.put_env(:openagents, :test_recall_backend_observer, self())
    snapshot = Registry.current!()
    tool = Map.fetch!(snapshot.tools, "conversation_search")
    call = recall_call(tool, "blocking history")

    assert {:ok, timed_out} = Runner.run(snapshot, call, context, timeout_ms: 10)
    assert_receive {:recall_backend_started, _backend_pid}
    assert timed_out["status"] == "failed"
    assert timed_out["error"]["code"] == "timeout"

    cancellation = :atomics.new(1, [])

    task =
      Task.async(fn ->
        Runner.run(snapshot, call, context, cancel?: fn -> :atomics.get(cancellation, 1) == 1 end)
      end)

    assert_receive {:recall_backend_started, _backend_pid}
    :atomics.put(cancellation, 1, 1)
    assert {:ok, cancelled} = Task.await(task)
    assert cancelled["status"] == "cancelled"
    assert cancelled["error"]["code"] == "cancelled"
  end

  test "search and read cover terminal tool steps from both surfaces" do
    {:ok, conversation} = Conversations.ensure_conversation("recall-tool-steps-browser")
    now = DateTime.utc_now()

    early =
      insert_message(
        conversation.id,
        "user",
        "Please check the ledger by voice.",
        DateTime.add(now, -180, :second)
      )

    voice_step =
      insert_voice_step(conversation, 1, "call-voice-1", %{
        tool_name: "github_repo_read",
        status: "succeeded",
        result: %{"finding" => "voice spectral-ledger-99 lookup"},
        completed_at: DateTime.add(now, -120, :second)
      })

    first_turn = begin_inference(conversation, "Use durable tools please.")

    assert {:ok, requested, :created} =
             request_step(first_turn.turn, first_turn.receipt, "call-turn-1", "item-turn-1", "{}")

    assert {:ok, turn_step} =
             Conversations.complete_tool_step(
               requested,
               step_outcome(requested, "succeeded", %{
                 "finding" => "turn spectral-ledger-99 receipt"
               })
             )

    assert {:ok, _message} =
             Conversations.append_assistant_delta(first_turn.turn, "Checked the ledger.")

    assert {:ok, _turn} = Conversations.complete_turn(first_turn.turn, "response-ledger-1")

    %{receipt: receipt} = begin_inference(conversation, "Did you already look that up?")
    context = execution_context(conversation, receipt)

    search = run_tool("conversation_search", ~s({"query":"spectral-ledger-99"}), context)
    assert search["status"] == "succeeded"
    assert search["result"]["status"] == "matches"

    matches = search["result"]["matches"]
    refs = Enum.map(matches, & &1["source_ref"])
    assert "turn-tool-step:#{turn_step.id}" in refs
    assert "voice-tool-step:#{voice_step.id}" in refs

    for match <- matches do
      assert match["role"] == "tool_activity"
      assert match["excerpt"] =~ "spectral-ledger-99"
      assert byte_size(match["excerpt"]) <= 800
    end

    assert search["target_receipt_refs"] == refs

    turn_read =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "turn-tool-step:#{turn_step.id}"}),
        context
      )

    assert turn_read["status"] == "succeeded"
    assert turn_read["result"]["source_ref"] == "turn-tool-step:#{turn_step.id}"
    assert turn_read["result"]["tool_step"]["surface"] == "text"
    assert turn_read["result"]["tool_step"]["tool_name"] == "recall_messages"
    assert turn_read["result"]["tool_step"]["status"] == "succeeded"
    assert turn_read["result"]["tool_step"]["executor_disclosure"] == "Sarah local recall"
    assert turn_read["result"]["tool_step"]["argument_digest"] == turn_step.argument_digest
    assert turn_read["result"]["tool_step"]["completed_at"]
    assert turn_read["result"]["tool_step"]["result"] =~ "spectral-ledger-99"
    assert turn_read["result"]["evidence"]["source_ref"] == "turn-tool-step:#{turn_step.id}"
    assert turn_read["result"]["evidence"]["classification"] == "applicable"

    turn_read_roles =
      Enum.map(turn_read["result"]["messages"], &{&1["role"], &1["source_ref"]})

    assert {"tool_activity", "turn-tool-step:#{turn_step.id}"} == List.last(turn_read_roles)
    assert Enum.count(turn_read_roles, fn {role, _ref} -> role != "tool_activity" end) == 2

    voice_read =
      run_tool(
        "conversation_read",
        Jason.encode!(%{
          "source_ref" => "voice-tool-step:#{voice_step.id}",
          "before" => 1,
          "after" => 1
        }),
        context
      )

    assert voice_read["status"] == "succeeded"
    assert voice_read["result"]["tool_step"]["surface"] == "voice"
    assert voice_read["result"]["tool_step"]["status"] == "succeeded"
    assert voice_read["result"]["tool_step"]["result"] =~ "spectral-ledger-99"

    voice_read_refs = Enum.map(voice_read["result"]["messages"], & &1["source_ref"])
    assert Enum.at(voice_read_refs, 0) == "message:#{early.id}"
    assert Enum.at(voice_read_refs, 1) == "voice-tool-step:#{voice_step.id}"
    assert match?("message:" <> _, Enum.at(voice_read_refs, 2))

    step_entry = Enum.at(voice_read["result"]["messages"], 1)
    assert step_entry["role"] == "tool_activity"
    assert step_entry["content"] =~ "tool github_repo_read succeeded"
    assert step_entry["content"] =~ "executor:"
  end

  test "foreign and unknown tool step refs share one safe not-found outcome" do
    {:ok, first} = Conversations.ensure_conversation("recall-tool-steps-first-browser")
    {:ok, second} = Conversations.ensure_conversation("recall-tool-steps-second-browser")

    foreign_step =
      insert_voice_step(first, 1, "call-foreign-1", %{
        tool_name: "github_repo_read",
        status: "succeeded",
        result: %{"finding" => "private foreign ledger"},
        completed_at: DateTime.add(DateTime.utc_now(), -120, :second)
      })

    insert_message(second.id, "user", "Unrelated history.", DateTime.utc_now())
    %{receipt: receipt} = begin_inference(second, "Read a tool step.")
    context = execution_context(second, receipt)

    foreign_outcome =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "voice-tool-step:#{foreign_step.id}"}),
        context
      )

    unknown_outcome =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "turn-tool-step:#{Ecto.UUID.generate()}"}),
        context
      )

    assert foreign_outcome["status"] == "failed"
    assert foreign_outcome["error"]["code"] == "not_found"
    assert unknown_outcome["status"] == "failed"
    assert unknown_outcome["error"] == foreign_outcome["error"]

    search = run_tool("conversation_search", ~s({"query":"foreign ledger"}), context)
    assert search["result"]["status"] == "empty"
  end

  test "the frozen snapshot fences out tool steps completed after it" do
    {:ok, conversation} = Conversations.ensure_conversation("recall-tool-steps-fence-browser")
    now = DateTime.utc_now()

    admitted_step =
      insert_voice_step(conversation, 1, "call-admitted", %{
        tool_name: "github_repo_read",
        status: "succeeded",
        result: %{"finding" => "fenced-quasar-7 admitted"},
        completed_at: DateTime.add(now, -120, :second)
      })

    # The watermark message is inserted after the admitted step completed, so
    # the step sits below the frozen high-water instant.
    insert_message(
      conversation.id,
      "user",
      "Historic anchor message.",
      DateTime.add(now, -60, :second)
    )

    %{turn: turn, receipt: receipt} = begin_inference(conversation, "What ran already?")
    context = execution_context(conversation, receipt)

    later_step =
      insert_voice_step(conversation, 2, "call-later", %{
        tool_name: "github_repo_read",
        status: "succeeded",
        result: %{"finding" => "fenced-quasar-7 later"},
        completed_at: DateTime.add(now, 3_600, :second)
      })

    assert {:ok, in_flight_requested, :created} =
             request_step(turn, receipt, "call-in-flight", "item-in-flight", "{}")

    assert {:ok, in_flight_step} =
             Conversations.complete_tool_step(
               in_flight_requested,
               step_outcome(in_flight_requested, "succeeded", %{
                 "finding" => "fenced-quasar-7 in-flight"
               })
             )

    search = run_tool("conversation_search", ~s({"query":"fenced-quasar-7"}), context)
    assert search["status"] == "succeeded"

    assert Enum.map(search["result"]["matches"], & &1["source_ref"]) == [
             "voice-tool-step:#{admitted_step.id}"
           ]

    for fenced_ref <- [
          "voice-tool-step:#{later_step.id}",
          "turn-tool-step:#{in_flight_step.id}"
        ] do
      fenced_read =
        run_tool("conversation_read", Jason.encode!(%{"source_ref" => fenced_ref}), context)

      assert fenced_read["status"] == "failed"
      assert fenced_read["error"]["code"] == "not_found"
    end

    admitted_read =
      run_tool(
        "conversation_read",
        Jason.encode!(%{"source_ref" => "voice-tool-step:#{admitted_step.id}"}),
        context
      )

    assert admitted_read["status"] == "succeeded"
    assert admitted_read["result"]["tool_step"]["result"] =~ "admitted"
  end

  defp run_tool(name, raw_arguments, context) do
    snapshot = Registry.current!()
    tool = Map.fetch!(snapshot.tools, name)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               %{
                 call_id: "call-#{name}-#{System.unique_integer([:positive])}",
                 name: name,
                 version: tool.version,
                 raw_arguments: raw_arguments
               },
               context
             )

    outcome
  end

  defp recall_call(tool, query) do
    %{
      call_id: "call-degradation-#{System.unique_integer([:positive])}",
      name: tool.name,
      version: tool.version,
      raw_arguments: Jason.encode!(%{"query" => query})
    }
  end

  defp begin_inference(conversation, prompt) do
    assert {:ok, records} = Conversations.create_turn(conversation, prompt)
    context = Composer.compose!()

    request = %Request{
      model_id: "recall-tools-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider",
               tool_catalog_digest: Registry.current!().digest
             )

    inference
  end

  defp execution_context(conversation, receipt) do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{conversation.id}",
      authorities: MapSet.new(["conversation.read"]),
      conversation_id: conversation.id,
      memory_snapshot_ref: receipt.memory_snapshot_ref
    }
  end

  defp insert_message(conversation_id, role, content, timestamp) do
    Repo.insert!(%Message{
      conversation_id: conversation_id,
      role: role,
      content: content,
      status: "complete",
      inserted_at: timestamp,
      updated_at: timestamp
    })
  end

  defp insert_voice_step(conversation, sequence, call_id, attrs) do
    session = voice_session(conversation)

    receipt =
      Repo.insert!(
        VoiceResponseReceipt.create_changeset(%VoiceResponseReceipt{}, %{
          voice_session_id: session.id,
          generation: session.generation,
          provider_response_id: "response-#{call_id}",
          status: "responding",
          started_event_sequence: sequence,
          usage: %{}
        })
      )

    {:ok, requested} =
      %VoiceToolStep{}
      |> VoiceToolStep.requested_changeset(%{
        voice_session_id: session.id,
        voice_response_receipt_id: receipt.id,
        generation: session.generation,
        sequence: sequence,
        provider_call_id: call_id,
        provider_item_id: "item-#{call_id}",
        provider_response_id: "response-#{call_id}",
        tool_name: attrs.tool_name,
        tool_version: 1,
        module_id: "sarah.tool.#{attrs.tool_name}.v1",
        catalog_digest: sha256("catalog-#{call_id}"),
        argument_digest: sha256("arguments-#{call_id}"),
        status: "requested",
        requested_at: DateTime.add(attrs.completed_at, -1, :second)
      })
      |> Repo.insert()

    {:ok, step} =
      requested
      |> VoiceToolStep.terminal_changeset(%{
        status: attrs.status,
        outcome_digest: sha256("outcome-#{call_id}"),
        result: attrs[:result],
        error: attrs[:error],
        executor_id: "sarah.test.voice",
        executor_disclosure: "Sarah voice test executor",
        target_receipt_refs: [],
        attribution_refs: [],
        completed_at: attrs.completed_at
      })
      |> Repo.update()

    step
  end

  defp voice_session(conversation) do
    existing =
      Repo.one(
        from(session in OpenAgents.Voice.Session,
          where: session.conversation_id == ^conversation.id,
          order_by: [desc: session.generation],
          limit: 1
        )
      )

    if existing do
      existing
    else
      {:ok, session} = Voice.admit_session(conversation, voice_config())
      session
    end
  end

  defp voice_config do
    VoiceConfig.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end

  defp sha256(seed), do: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)

  defp request_step(turn, receipt, call_id, item_id, raw_arguments) do
    artifact = module_artifact()
    routing_receipt = routing_receipt!(receipt, call_id, artifact)
    policy = artifact.attribution_policy

    Conversations.request_tool_step(turn, receipt, %{
      provider_call_id: call_id,
      provider_item_id: item_id,
      provider_response_id: "response-#{call_id}",
      tool_name: "recall_messages",
      tool_version: 1,
      module_id: "sarah.tool.recall_messages",
      module_artifact_digest: artifact.artifact_digest,
      executor_implementation_digest: artifact.implementation_digest,
      routing_receipt_id: routing_receipt.id,
      side_effect_class: artifact.side_effect_class,
      attribution_policy_id: policy["id"],
      attribution_policy_version: policy["version"],
      attribution_policy_digest: policy["digest"],
      cost_units: artifact.facets["cost_units"],
      raw_arguments: raw_arguments
    })
  end

  defp step_outcome(step, status, result) do
    %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version,
        "artifact_digest" => step.module_artifact_digest
      },
      "executor_ref" => %{
        "id" => "sarah.local",
        "disclosure" => "Sarah local recall",
        "implementation_digest" => step.executor_implementation_digest
      },
      "status" => status,
      "result" => result,
      "error" => nil,
      "target_receipt_refs" => [],
      "attribution_refs" => ["OpenAgentsInc/sarah"],
      "started_at" => "2026-08-16T20:00:00Z",
      "completed_at" => "2026-08-16T20:00:01Z"
    }
  end

  defp module_artifact do
    Map.fetch!(Registry.current!().modules, {"sarah.tool.recall_messages", 1})
  end

  defp routing_receipt!(receipt, call_id, artifact) do
    snapshot = Registry.current!()
    policy = OpenAgents.Modules.RoutingPolicy.default()

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => snapshot.digest
    }

    assert {:ok, decision} =
             OpenAgents.Modules.Router.route(snapshot, policy, %{
               intent_digest: receipt.input_digest,
               required_capability: "conversation.read",
               required_side_effect: "read_only",
               surface: "text",
               data_scope: "browser_conversation",
               authorities: MapSet.new(["conversation.read"]),
               proposal: proposal,
               exact_proposal: true
             })

    assert {:ok, route} =
             OpenAgents.Modules.RoutingReceipts.persist(receipt.id, call_id, decision)

    route
  end
end
