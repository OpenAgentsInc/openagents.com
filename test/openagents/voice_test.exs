defmodule OpenAgents.VoiceTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.{Conversations, Voice}
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.Voice.{Config, ProviderEvent, Session}

  test "admits one immutable generation and fences duplicate, stale, and terminal work" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-generation-browser")
    assert {:ok, first} = Voice.admit_session(conversation, enabled_config())
    assert first.generation == 1
    assert first.status == "connecting"
    assert first.voice_artifact_id == "sarah.voice.openai.marin.v1"
    assert first.role_selection["schema"] == "sarah.role_selection.v1"
    assert first.role_selection["surface"] == "voice"
    assert first.role_selection["role_id"] == first.role_id
    assert first.role_selection["role_digest"] == first.role_digest
    assert byte_size(first.instruction_digest) == 64
    assert byte_size(first.tool_catalog_digest) == 64

    assert {:error, :voice_session_in_progress} =
             Voice.admit_session(conversation, enabled_config())

    assert {:ok, attached} = Voice.attach_provider(first, 1, "rtc_generation_1")

    ready = event(:session_ready, "evt-ready", %{})

    assert {:ok, listening, persisted, :created} =
             Voice.record_provider_event(attached, 1, ready)

    assert listening.status == "listening"
    assert listening.event_sequence == 1
    assert persisted.sequence == 1

    assert {:ok, duplicate_session, duplicate_event, :duplicate} =
             Voice.record_provider_event(listening, 1, ready)

    assert duplicate_session.event_sequence == 1
    assert duplicate_event.id == persisted.id

    assert {:error, :stale_voice_generation} =
             Voice.record_provider_event(listening, 2, event(:speech_started, "evt-stale", %{}))

    assert {:ok, ended} = Voice.end_session(listening, 1, "user_ended")
    assert ended.status == "ended"
    assert ended.termination_reason == "user_ended"

    assert {:error, :voice_session_terminal} =
             Voice.record_provider_event(ended, 1, event(:speech_started, "evt-late", %{}))

    assert {:ok, second} = Voice.admit_session(conversation, enabled_config())
    assert second.generation == 2
  end

  test "persists only finalized transcript evidence and provider-reported usage" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-transcript-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, session} = Voice.attach_provider(session, session.generation, "rtc_transcript")

    events = [
      event(:session_ready, "evt-ready", %{}),
      event(:response_started, "evt-start", %{"response_id" => "response-1"}),
      event(:user_transcript_final, "evt-user", %{
        "item_id" => "item-user",
        "response_id" => nil,
        "content" => "What do you remember?"
      }),
      event(:assistant_transcript_final, "evt-assistant", %{
        "item_id" => "item-assistant",
        "response_id" => "response-1",
        "content" => "I can search this browser conversation."
      }),
      event(:response_completed, "evt-done", %{
        "response_id" => "response-1",
        "status" => "completed",
        "usage" => %{
          "input_tokens" => 12,
          "output_tokens" => 8,
          "total_tokens" => 20
        }
      })
    ]

    final_session =
      Enum.reduce(events, session, fn provider_event, current_session ->
        assert {:ok, updated_session, _persisted, :created} =
                 Voice.record_provider_event(
                   current_session,
                   current_session.generation,
                   provider_event
                 )

        updated_session
      end)

    assert final_session.status == "listening"
    assert final_session.event_sequence == 5

    assert final_session.usage["input_tokens"] == 12
    assert final_session.usage["output_tokens"] == 8
    assert final_session.usage["total_tokens"] == 20
    assert final_session.usage["input_unclassified_tokens"] == 12
    assert final_session.usage["output_unclassified_tokens"] == 8
    assert final_session.usage["estimated_cost_microusd"] == 896
    assert final_session.usage["pricing_id"] == "openai.gpt-realtime-2.1.2026-08-16"

    assert [user, assistant] = Voice.list_transcript_items(final_session)
    assert {user.role, user.status, user.content} == {"user", "final", "What do you remember?"}

    assert {assistant.role, assistant.provider_response_id, assistant.status} ==
             {"assistant", "response-1", "final"}

    assert [receipt] = Voice.list_response_receipts(final_session)
    assert receipt.provider_response_id == "response-1"
    assert receipt.status == "completed"
    assert receipt.started_event_sequence == 2
    assert receipt.terminal_event_sequence == 5
    assert receipt.usage == final_session.usage
  end

  test "rejects transcript and completion events that precede their response receipt" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-order-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    assert {:error, :voice_response_not_started} =
             Voice.record_provider_event(
               session,
               session.generation,
               event(:assistant_transcript_final, "evt-transcript", %{
                 "item_id" => "item-assistant",
                 "response_id" => "response-missing",
                 "content" => "This must not commit."
               })
             )

    assert {:error, :voice_response_not_started} =
             Voice.record_provider_event(
               session,
               session.generation,
               event(:response_completed, "evt-done", %{
                 "response_id" => "response-missing",
                 "status" => "completed",
                 "usage" => %{}
               })
             )

    unchanged = Voice.get_session!(session.id)
    assert unchanged.event_sequence == 0
    assert Voice.list_events(unchanged) == []
    assert Voice.list_response_receipts(unchanged) == []
    assert Voice.list_transcript_items(unchanged) == []
  end

  test "an interrupted response cannot produce an authoritative final assistant line" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-interrupted-line-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    {:ok, responding, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:response_started, "evt-start", %{"response_id" => "response-interrupted"})
      )

    {:ok, interrupted, _event, :created} =
      Voice.record_provider_event(
        responding,
        responding.generation,
        event(:speech_started, "evt-interrupt", %{})
      )

    assert {:ok, interrupted, _event, :created} =
             Voice.record_provider_event(
               interrupted,
               interrupted.generation,
               event(:assistant_transcript_final, "evt-transcript", %{
                 "item_id" => "item-interrupted",
                 "response_id" => "response-interrupted",
                 "content" => "A cut-off assistant sentence"
               })
             )

    assert [%{status: "interrupted"}] = Voice.list_response_receipts(interrupted)
    assert [%{status: "interrupted"}] = Voice.list_transcript_items(interrupted)
  end

  test "a response with multiple transcript items persists them all without conflict" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-multi-item-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    events = [
      event(:response_started, "evt-start", %{"response_id" => "response-multi"}),
      event(:assistant_transcript_final, "evt-item-one", %{
        "item_id" => "item-one",
        "response_id" => "response-multi",
        "content" => "First item of the answer."
      }),
      event(:speech_started, "evt-interrupt", %{}),
      event(:assistant_transcript_final, "evt-item-two", %{
        "item_id" => "item-two",
        "response_id" => "response-multi",
        "content" => "Second item cut off by the interruption."
      }),
      event(:response_completed, "evt-done", %{
        "response_id" => "response-multi",
        "status" => "cancelled",
        "usage" => %{}
      })
    ]

    final_session =
      Enum.reduce(events, session, fn provider_event, current_session ->
        assert {:ok, updated_session, _persisted, :created} =
                 Voice.record_provider_event(
                   current_session,
                   current_session.generation,
                   provider_event
                 )

        updated_session
      end)

    assert final_session.status == "listening"

    assert [%{status: "interrupted"} = receipt] = Voice.list_response_receipts(final_session)

    assert [%{status: "interrupted"}, %{status: "interrupted"}] =
             Voice.list_transcript_items(final_session)

    messages =
      Repo.all(
        from(message in OpenAgents.Conversations.Message,
          where:
            message.voice_session_id == ^final_session.id and
              message.provider_response_id == "response-multi",
          order_by: [asc: message.inserted_at]
        )
      )

    assert length(messages) == 2
    assert Enum.all?(messages, &(&1.status == "cancelled" and &1.interrupted))
    assert receipt.assistant_message_id == hd(messages).id
  end

  test "explicit interruption is state-checked and durable" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-explicit-interrupt-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    assert {:error, :voice_not_responding} =
             Voice.interrupt_response(session, session.generation)

    {:ok, responding, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:response_started, "evt-start", %{"response_id" => "response-control"})
      )

    assert {:ok, interrupted, persisted, :created} =
             Voice.interrupt_response(responding, responding.generation)

    assert interrupted.status == "interrupted"
    assert persisted.kind == "response_cancelled"
    assert persisted.payload == %{"source" => "user_control"}
    assert [%{status: "interrupted"}] = Voice.list_response_receipts(interrupted)

    assert {:error, :voice_not_responding} =
             Voice.interrupt_response(interrupted, interrupted.generation)
  end

  test "text, finalized voice, and later text share one authoritative chronology" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-cross-modal-browser")

    {:ok, first_text} = Conversations.create_turn(conversation, "Typed before voice")
    assert {:ok, _message} = Conversations.append_assistant_delta(first_text.turn, "Before reply")
    assert {:ok, _turn} = Conversations.complete_turn(first_text.turn, "response-before", %{})

    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    voice_events = [
      event(:user_transcript_final, "evt-cross-user", %{
        "item_id" => "item-cross-user",
        "response_id" => nil,
        "content" => "Spoken middle"
      }),
      event(:response_started, "evt-cross-start", %{"response_id" => "response-cross"}),
      event(:assistant_transcript_final, "evt-cross-assistant", %{
        "item_id" => "item-cross-assistant",
        "response_id" => "response-cross",
        "content" => "Spoken reply"
      }),
      event(:response_completed, "evt-cross-done", %{
        "response_id" => "response-cross",
        "status" => "completed",
        "usage" => %{}
      })
    ]

    final_session =
      Enum.reduce(voice_events, session, fn provider_event, current_session ->
        assert {:ok, updated_session, _persisted, :created} =
                 Voice.record_provider_event(
                   current_session,
                   current_session.generation,
                   provider_event
                 )

        updated_session
      end)

    assert {:ok, _ended} = Voice.end_session(final_session, final_session.generation, "test")

    {:ok, last_text} = Conversations.create_turn(conversation, "Typed after voice")
    assert {:ok, _message} = Conversations.append_assistant_delta(last_text.turn, "After reply")
    assert {:ok, _turn} = Conversations.complete_turn(last_text.turn, "response-after", %{})

    assert Conversations.provider_messages(conversation.id)
           |> Enum.map(&{&1.role, &1.content}) == [
             {"assistant", OpenAgents.Persona.greeting()},
             {"user", "Typed before voice"},
             {"assistant", "Before reply"},
             {"user", "Spoken middle"},
             {"assistant", "Spoken reply"},
             {"user", "Typed after voice"},
             {"assistant", "After reply"}
           ]

    assert [user, assistant] = Voice.list_transcript_items(final_session)
    assert Repo.get!(OpenAgents.Conversations.Message, user.message_id).status == "complete"
    assert Repo.get!(OpenAgents.Conversations.Message, assistant.message_id).status == "complete"

    user_message = Repo.get!(OpenAgents.Conversations.Message, user.message_id)

    assert_raise Postgrex.Error, fn ->
      user_message
      |> OpenAgents.Conversations.Message.changeset(%{content: "silently rewritten"})
      |> Repo.update!()
    end
  end

  test "bounds repeated anonymous voice admission in a database window" do
    previous_limit = Application.fetch_env!(:openagents, :voice_attempt_limit)
    previous_window = Application.fetch_env!(:openagents, :voice_attempt_window_seconds)
    Application.put_env(:openagents, :voice_attempt_limit, 2)
    Application.put_env(:openagents, :voice_attempt_window_seconds, 600)

    on_exit(fn ->
      Application.put_env(:openagents, :voice_attempt_limit, previous_limit)
      Application.put_env(:openagents, :voice_attempt_window_seconds, previous_window)
    end)

    {:ok, conversation} = Conversations.ensure_conversation("voice-rate-browser")
    {:ok, first} = Voice.admit_session(conversation, enabled_config())
    {:ok, _first_ended} = Voice.end_session(first, first.generation, "test")
    {:ok, second} = Voice.admit_session(conversation, enabled_config())
    {:ok, _second_ended} = Voice.end_session(second, second.generation, "test")

    assert {:error, :voice_rate_limited} = Voice.admit_session(conversation, enabled_config())
  end

  test "startup recovery fails every active row without inventing transcript or usage" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-recovery-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    recovery = start_supervised!({OpenAgents.VoiceRecovery, []})
    _state = :sys.get_state(recovery)

    recovered = Repo.get!(Session, session.id)
    assert recovered.status == "failed"
    assert recovered.termination_reason == "runtime_restart"
    assert recovered.failure_code == "runtime_interrupted"
    assert recovered.usage == %{}
    assert Voice.list_events(recovered) == []
    assert Voice.list_response_receipts(recovered) == []
    assert Voice.list_transcript_items(recovered) == []
  end

  test "voice tool calls durably normalize unauthorized, malformed, unknown, and stale work" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-tool-refusal-browser")
    owner = Conversations.get_conversation_owner!(conversation)
    snapshot = Registry.current!()
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:user_transcript_final, "evt-user-tools", %{
          "item_id" => "item-user-tools",
          "response_id" => nil,
          "content" => "Try these tool requests."
        })
      )

    assert {:ok, context} =
             Voice.capture_response_context(session, "item-user-tools", snapshot)

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:response_started, "evt-start-tools", %{"response_id" => "response-tools"}),
        response_context: context
      )

    unauthorized =
      execute_tool(
        session,
        snapshot,
        owner,
        context,
        "call-unauthorized",
        "conversation_search",
        ~s({"query":"history"}),
        MapSet.new()
      )

    assert unauthorized.status == "refused"
    assert unauthorized.error["code"] == "authority_refused"

    malformed =
      execute_tool(
        session,
        snapshot,
        owner,
        context,
        "call-malformed",
        "memory_list",
        "{not-json",
        MapSet.new(["memory.read"])
      )

    assert malformed.status == "failed"
    assert malformed.error["code"] == "invalid_arguments_json"

    unavailable =
      execute_tool(
        session,
        snapshot,
        owner,
        context,
        "call-unknown",
        "not_admitted",
        "{}",
        MapSet.new(["conversation.read"])
      )

    assert unavailable.status == "unavailable"
    assert unavailable.error["code"] == "unknown_tool"

    pending_event =
      event(:tool_call_requested, "evt-tool-stale", %{
        "response_id" => "response-tools",
        "item_id" => "item-call-stale",
        "call_id" => "call-stale",
        "tool_name" => "memory_list",
        "raw_arguments" => ~s({"category":"","first":1})
      })

    {:ok, session, _event, :created} =
      Voice.record_provider_event(session, session.generation, pending_event)

    assert {:ok, pending, :created} = Voice.request_tool_step(session, pending_event, snapshot)
    assert {:ok, running, :started} = Voice.start_tool_step(session, pending)
    assert {:ok, ended} = Voice.end_session(session, session.generation, "test_end")

    assert {:error, :voice_session_terminal} =
             Voice.complete_tool_step(ended, running, successful_outcome(running))

    assert Enum.map(Voice.list_tool_steps(ended), &{&1.provider_call_id, &1.status}) == [
             {"call-unauthorized", "refused"},
             {"call-malformed", "failed"},
             {"call-unknown", "unavailable"},
             {"call-stale", "cancelled"}
           ]
  end

  test "a refused host limit is durable and keyed to the assistant message it belongs to" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-durable-activity-browser")
    snapshot = Registry.current!()
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:user_transcript_final, "evt-user-activity", %{
          "item_id" => "item-user-activity",
          "response_id" => nil,
          "content" => "Keep looking things up."
        })
      )

    assert {:ok, context} =
             Voice.capture_response_context(session, "item-user-activity", snapshot)

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:response_started, "evt-start-activity", %{"response_id" => "response-activity"}),
        response_context: context
      )

    request =
      event(:tool_call_requested, "evt-tool-activity", %{
        "response_id" => "response-activity",
        "item_id" => "item-call-activity",
        "call_id" => "call-activity",
        "tool_name" => "memory_list",
        "raw_arguments" => ~s({"category":"","first":1})
      })

    {:ok, session, _event, :created} =
      Voice.record_provider_event(session, session.generation, request)

    assert {:ok, requested, :created} = Voice.request_tool_step(session, request, snapshot)

    assert {:ok, refused} =
             Voice.refuse_tool_step(
               session,
               requested,
               "tool_call_limit_reached",
               "This turn reached the host limit of 8 tool calls."
             )

    assert refused.status == "refused"
    assert refused.error["code"] == "tool_call_limit_reached"
    assert refused.executor_id == "sarah.host"

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:assistant_transcript_final, "evt-assistant-activity", %{
          "item_id" => "item-assistant-activity",
          "response_id" => "response-activity",
          "content" => "I stopped short of finishing."
        })
      )

    {:ok, session, _event, :created} =
      Voice.record_provider_event(
        session,
        session.generation,
        event(:response_completed, "evt-done-activity", %{
          "response_id" => "response-activity",
          "status" => "completed",
          "usage" => %{}
        })
      )

    assert [receipt] = Voice.list_response_receipts(session)
    assistant_message_id = receipt.assistant_message_id
    assert is_binary(assistant_message_id)

    assert %{^assistant_message_id => [activity]} =
             Voice.list_tool_step_activity_by_message([assistant_message_id])

    assert activity.tool_name == "memory_list"
    assert activity.status == "refused"
    assert activity.error["code"] == "tool_call_limit_reached"
    refute Map.has_key?(activity, :provider_call_id)

    assert Voice.list_tool_step_activity_by_message([]) == %{}
    assert Voice.list_tool_step_activity_by_message([Ecto.UUID.generate()]) == %{}
  end

  defp event(kind, event_id, payload) do
    %ProviderEvent{kind: kind, provider_event_id: event_id, payload: payload}
  end

  defp enabled_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end

  defp execute_tool(
         session,
         snapshot,
         owner,
         context,
         call_id,
         tool_name,
         raw_arguments,
         authorities
       ) do
    provider_event =
      event(:tool_call_requested, "evt-tool-#{call_id}", %{
        "response_id" => "response-tools",
        "item_id" => "item-#{call_id}",
        "call_id" => call_id,
        "tool_name" => tool_name,
        "raw_arguments" => raw_arguments
      })

    assert {:ok, session, _event, :created} =
             Voice.record_provider_event(session, session.generation, provider_event)

    assert {:ok, requested, :created} =
             Voice.request_tool_step(session, provider_event, snapshot)

    assert {:ok, running, :started} = Voice.start_tool_step(session, requested)

    execution_context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{session.conversation_id}",
      authorities: authorities,
      conversation_id: session.conversation_id,
      current_user_message_id: context.user_message_id,
      owner_visitor_id: owner.id,
      memory_snapshot_ref: context.memory_snapshot_ref,
      profile_memory_snapshot_ref: context.profile_memory_snapshot_ref
    }

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               %{
                 call_id: call_id,
                 name: tool_name,
                 version: running.tool_version,
                 raw_arguments: raw_arguments
               },
               execution_context
             )

    assert {:ok, completed} = Voice.complete_tool_step(session, running, outcome)
    completed
  end

  defp successful_outcome(step) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version
      },
      "executor_ref" => %{"id" => "test", "disclosure" => "test"},
      "status" => "succeeded",
      "result" => %{},
      "error" => nil,
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => now,
      "completed_at" => now
    }
  end
end
