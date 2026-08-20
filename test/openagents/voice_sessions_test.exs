defmodule OpenAgents.VoiceSessionsTest do
  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.{Conversations, Voice, VoiceSessions}
  alias OpenAgents.Voice.ProviderEvent

  setup do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    Application.put_env(:openagents, :voice, enabled_voice())
    Application.put_env(:openagents, :voice_call_test_observer, self())
    Application.put_env(:openagents, :voice_sideband_test_observer, self())

    on_exit(fn ->
      Application.put_env(:openagents, :voice, previous_voice)
      Application.delete_env(:openagents, :voice_call_test_observer)
      Application.delete_env(:openagents, :voice_sideband_test_observer)
    end)

    :ok
  end

  test "connects through the provider and persists normalized sideband events" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-runtime-browser")
    config = OpenAgents.Voice.Config.current!()

    assert {:ok, session, admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=runtime-offer",
               String.duplicate("a", 64),
               config
             )

    assert admission.answer_sdp == "v=0\r\no=test-answer"
    assert session.provider_session_id == "rtc_test"
    assert_receive {:voice_call, "v=0\r\no=runtime-offer", _identifier, runtime_config}
    assert runtime_config.instructions == session.instructions
    assert runtime_config.tools == session.tool_catalog["tools"]
    assert runtime_config.model == config.model
    assert_receive {:sideband_started, sideband, sideband_session}
    assert sideband_session.id == session.id

    process = VoiceSessions.whereis(session.id)
    assert is_pid(process)
    _state = :sys.get_state(process)
    assert Voice.get_session!(session.id).status == "listening"

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{kind: :session_ready, provider_event_id: "evt-ready", payload: %{}}
    })

    prepare_response(sideband, session, "item-user-runtime", "Tell me who you are.")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-response",
        payload: %{"response_id" => "response-1"}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-assistant",
        payload: %{
          "item_id" => "item-assistant",
          "response_id" => "response-1",
          "content" => "A durable final line."
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-completed",
        payload: %{
          "response_id" => "response-1",
          "status" => "completed",
          "usage" => %{}
        }
      }
    })

    expected_event_kinds = [
      "sideband_connected",
      "session_ready",
      "user_transcript_final",
      "response_started",
      "assistant_transcript_final",
      "response_completed"
    ]

    stored = await_event_kinds(session.id, expected_event_kinds)
    assert stored.status == "listening"

    assert Enum.map(Voice.list_events(stored), & &1.kind) == expected_event_kinds

    assert [
             %{role: "user", content: "Tell me who you are."},
             %{role: "assistant", content: "A durable final line."}
           ] = Voice.list_transcript_items(stored)

    assert {:ok, ended} = VoiceSessions.end_session(stored)
    assert ended.status == "ended"
  end

  test "streams live transcript deltas to subscribers without persisting them" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-live-delta-browser")
    :ok = Voice.subscribe(conversation)

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=live-delta-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    prepare_response(sideband, session, "item-user-live", "Say something long.")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-response",
        payload: %{"response_id" => "response-live"}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_delta,
        provider_event_id: "evt-delta-1",
        payload: %{"item_id" => "item-assistant-live", "delta" => "The first"}
      }
    })

    assert_receive {:voice_live_transcript,
                    %{item_id: "item-assistant-live", role: "assistant", content: "The first"}}

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_delta,
        provider_event_id: "evt-delta-2",
        payload: %{"item_id" => "item-assistant-live", "delta" => " words."}
      }
    })

    assert_receive {:voice_live_transcript,
                    %{item_id: "item-assistant-live", content: "The first words."}}

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-final",
        payload: %{
          "item_id" => "item-assistant-live",
          "response_id" => "response-live",
          "content" => "The first words."
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done",
        payload: %{"response_id" => "response-live", "status" => "completed", "usage" => %{}}
      }
    })

    stored =
      await_event_kinds(session.id, [
        "sideband_connected",
        "user_transcript_final",
        "response_started",
        "assistant_transcript_final",
        "response_completed"
      ])

    refute Enum.any?(Voice.list_events(stored), &String.contains?(&1.kind, "delta"))

    state = :sys.get_state(VoiceSessions.whereis(session.id))
    assert state.live_transcripts == %{}

    assert [
             %{role: "user", content: "Say something long."},
             %{role: "assistant", content: "The first words."}
           ] = Voice.list_transcript_items(stored)

    assert {:ok, _ended} = VoiceSessions.end_session(stored)
  end

  test "barge-in cancels the live provider response and durably interrupts its receipt" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-interruption-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=interruption-offer",
               String.duplicate("d", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    prepare_response(sideband, session, "item-user-interruption", "Explain this briefly.")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-response-started",
        payload: %{"response_id" => "response-interrupted"}
      }
    })

    responding = await_session_status(session.id, "responding")

    send(sideband, {
      :provider_event,
      responding,
      %ProviderEvent{
        kind: :speech_started,
        provider_event_id: "evt-speech-started",
        payload: %{"item_id" => "item-user"}
      }
    })

    interrupted = await_session_status(session.id, "interrupted")
    assert_receive {:sideband_event_sent, %{"type" => "response.cancel"}}

    assert [%{status: "interrupted", terminal_event_sequence: 4}] =
             Voice.list_response_receipts(interrupted)

    assert {:ok, _ended} = VoiceSessions.end_session(interrupted)
  end

  test "a late cancelled completion after a completed response keeps the session alive" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-late-cancel-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=late-cancel-offer",
               String.duplicate("f", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    usage = %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}

    finish_response_with_usage(sideband, session, "response-late", "item-user-late", usage)

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :speech_started,
        provider_event_id: "evt-late-speech",
        payload: %{"item_id" => "item-user-late-2"}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-late-cancelled",
        payload: %{"response_id" => "response-late", "status" => "cancelled", "usage" => usage}
      }
    })

    stored =
      await_event_kinds(session.id, [
        "sideband_connected",
        "user_transcript_final",
        "response_started",
        "assistant_transcript_final",
        "response_completed",
        "speech_started",
        "response_completed"
      ])

    assert stored.status == "listening"
    assert stored.failure_code == nil
    assert stored.usage["total_tokens"] == 15
    assert is_pid(VoiceSessions.whereis(session.id))

    assert {:ok, ended} = VoiceSessions.end_session(stored)
    assert ended.status == "ended"
  end

  test "explicit interrupt control commits before provider cancellation" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-control-interruption-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=control-interruption-offer",
               String.duplicate("e", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    prepare_response(sideband, session, "item-user-control", "Start an answer.")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-control-response",
        payload: %{"response_id" => "response-controlled"}
      }
    })

    responding = await_session_status(session.id, "responding")

    assert {:ok, interrupted} = VoiceSessions.interrupt_session(responding)
    assert interrupted.status == "interrupted"
    assert_receive {:sideband_event_sent, %{"type" => "response.cancel"}}

    assert Enum.map(Voice.list_events(interrupted), & &1.kind) == [
             "sideband_connected",
             "user_transcript_final",
             "response_started",
             "response_cancelled"
           ]

    assert [%{status: "interrupted"}] = Voice.list_response_receipts(interrupted)
    assert {:ok, _ended} = VoiceSessions.end_session(interrupted)
  end

  test "sideband loss is explicit and reconnects under the same generation" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-reconnect-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=reconnect-offer",
               String.duplicate("b", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, first_sideband, _first_session}
    process = VoiceSessions.whereis(session.id)
    _state = :sys.get_state(process)

    send(first_sideband, :disconnect)

    assert_receive {:sideband_started, second_sideband, second_session}, 2_000
    refute second_sideband == first_sideband
    assert second_session.generation == session.generation
    _state = :sys.get_state(process)

    stored = Voice.get_session!(session.id)
    assert stored.status in ["connecting", "listening"]
    assert Enum.any?(Voice.list_events(stored), &(&1.kind == "sideband_disconnected"))

    assert {:ok, _ended} = VoiceSessions.end_session(stored)
  end

  test "a typed message is injected into the live provider conversation without ending the call" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-typed-inject-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=typed-inject-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, _sideband, _sideband_session}

    typed = "Check https://github.com/OpenAgentsInc/sarah please"
    assert {:ok, message} = Conversations.create_voice_context_message(conversation, typed)
    assert message.status == "complete"
    assert message.role == "user"

    assert :ok = VoiceSessions.inject_typed_message(session, message)

    assert_receive {:sideband_event_sent, %{"type" => "conversation.item.create", "item" => item}}

    assert item["role"] == "user"
    assert [%{"type" => "input_text", "text" => ^typed}] = item["content"]

    stored = Voice.get_session!(session.id)
    assert stored.status in ["connecting", "listening"]
    assert is_pid(VoiceSessions.whereis(session.id))
    assert {:ok, _ended} = VoiceSessions.end_session(stored)
  end

  test "a provider event trailing in after a terminal session stops the runtime without compounding failure" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-late-terminal-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=late-terminal-offer",
               String.duplicate("b", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}
    process = VoiceSessions.whereis(session.id)
    _state = :sys.get_state(process)

    assert {:ok, failed} =
             Voice.fail_session(
               Voice.get_session!(session.id),
               session.generation,
               :runtime_interrupted
             )

    assert failed.status == "failed"

    monitor = Process.monitor(process)

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :speech_started,
        provider_event_id: "evt-late-terminal",
        payload: %{"item_id" => "item-late-terminal"}
      }
    })

    assert_receive {:DOWN, ^monitor, :process, ^process, :normal}, 2_000

    stored = Voice.get_session!(session.id)
    assert stored.status == "failed"
    assert stored.failure_code == "runtime_interrupted"
  end

  test "an abnormal runtime restart deterministically fails the admitted generation" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-runtime-crash-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=crash-offer",
               String.duplicate("c", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, _sideband, _sideband_session}
    process = VoiceSessions.whereis(session.id)
    monitor = Process.monitor(process)
    Process.exit(process, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^process, :killed}
    recovered = await_session_status(session.id, "failed")
    assert recovered.status == "failed"
    assert recovered.failure_code == "runtime_process_restarted"
    assert VoiceSessions.whereis(session.id) == nil
  end

  test "approval-required and read-only tools use one governed voice runner and receipt trail" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-governed-tools-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=tools-offer",
               String.duplicate("f", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(
      sideband,
      session,
      "item-user-remember",
      "Remember that I prefer concise voice answers.",
      "response-remember-tool"
    )

    remember_output =
      request_tool(
        sideband,
        session,
        "response-remember-tool",
        "call-remember",
        "item-call-remember",
        "memory_remember",
        %{
          "memories" => [
            %{"category" => "preference", "claim" => "I prefer concise voice answers"}
          ]
        }
      )

    assert remember_output["output"]["status"] == "succeeded"
    assert remember_output["output"]["executor"]["id"] == "sarah.postgres.profile_memory"

    finish_response(
      sideband,
      session,
      "response-remember-answer",
      "item-assistant-remember",
      "I’ll remember that you prefer concise voice answers."
    )

    start_response(
      sideband,
      session,
      "item-user-list",
      "What do you remember about my answer preference?",
      "response-list-tool"
    )

    list_output =
      request_tool(
        sideband,
        session,
        "response-list-tool",
        "call-list",
        "item-call-list",
        "memory_list",
        %{"category" => "preference", "first" => 10}
      )

    assert list_output["output"]["status"] == "succeeded"
    assert [memory] = list_output["output"]["result"]["memories"]
    assert memory["claim"] == "I prefer concise voice answers"

    finish_response(
      sideband,
      session,
      "response-list-answer",
      "item-assistant-list",
      "You prefer concise voice answers."
    )

    stored = await_session_status(session.id, "listening")
    assert [remember_step, list_step] = Voice.list_tool_steps(stored)
    assert {remember_step.tool_name, remember_step.status} == {"memory_remember", "succeeded"}
    assert {list_step.tool_name, list_step.status} == {"memory_list", "succeeded"}

    assert remember_step.raw_arguments ==
             Jason.encode!(%{
               "memories" => [
                 %{"category" => "preference", "claim" => "I prefer concise voice answers"}
               ]
             })

    assert list_step.raw_arguments == Jason.encode!(%{"category" => "preference", "first" => 10})
    assert remember_step.argument_digest =~ ~r/^[0-9a-f]{64}$/
    assert list_step.argument_digest =~ ~r/^[0-9a-f]{64}$/

    assert [first_context, second_context] = Voice.list_response_contexts(stored)
    assert first_context.instruction_digest != second_context.instruction_digest

    assert second_context.selected_evidence["items"]
           |> Enum.any?(&(&1["classification"] == "active_profile_memory"))

    assert [first_tool_receipt, first_answer_receipt, list_tool_receipt, list_answer_receipt] =
             Voice.list_response_receipts(stored)

    assert first_tool_receipt.response_context_id == first_context.id
    assert first_answer_receipt.response_context_id == first_context.id
    assert list_tool_receipt.response_context_id == second_context.id
    assert list_answer_receipt.response_context_id == second_context.id
    assert first_tool_receipt.used_tool_step_refs == ["voice-tool-step:#{remember_step.id}"]
    assert first_answer_receipt.used_tool_step_refs == ["voice-tool-step:#{remember_step.id}"]
    assert list_tool_receipt.used_tool_step_refs == ["voice-tool-step:#{list_step.id}"]
    assert list_answer_receipt.used_tool_step_refs == ["voice-tool-step:#{list_step.id}"]

    tool_events =
      stored
      |> Voice.list_events()
      |> Enum.filter(&(&1.kind == "tool_call_requested"))

    assert Enum.all?(tool_events, fn event ->
             is_binary(event.payload["argument_digest"]) and
               byte_size(event.payload["argument_digest"]) == 64 and
               not Map.has_key?(event.payload, "raw_arguments")
           end)

    assert {:ok, _ended} = VoiceSessions.end_session(stored)
  end

  test "account deletion succeeds after voice responses left contexts and receipts" do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: 990_001,
        github_login: "voice-reset-owner",
        github_avatar_url: "https://avatars.githubusercontent.com/u/990001?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=reset-offer",
               String.duplicate("d", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(
      sideband,
      session,
      "item-user-reset",
      "Remember this exchange before the account deletion.",
      "response-reset"
    )

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-transcript-response-reset",
        payload: %{
          "response_id" => "response-reset",
          "item_id" => "item-assistant-reset",
          "content" => "Noted before the deletion."
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-response-reset",
        payload: %{"response_id" => "response-reset", "status" => "completed", "usage" => %{}}
      }
    })

    _listening = await_session_status(session.id, "listening")

    start_response(
      sideband,
      session,
      "item-user-search-del",
      "Search our conversation before the account deletion.",
      "response-del-tool"
    )

    sentinel = "zulu-quasar-sentinel"
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        search_output =
          request_tool(
            sideband,
            session,
            "response-del-tool",
            "call-del-search",
            "item-call-del-search",
            "conversation_search",
            %{"query" => sentinel}
          )

        assert search_output["output"]["status"] == "succeeded"
      end)

    refute log =~ sentinel
    Logger.configure(level: previous_level)

    stored = await_session_status(session.id, "listening")
    assert [_context, _tool_context] = Voice.list_response_contexts(stored)
    assert [tool_step] = Voice.list_tool_steps(stored)
    assert tool_step.raw_arguments == Jason.encode!(%{"query" => sentinel})
    assert {:ok, _ended} = VoiceSessions.end_session(stored)

    assert {:ok, export} = OpenAgents.DataRights.export(user, owner, conversation)
    assert [tool_entry] = export["tool_steps"]
    assert tool_entry["surface"] == "voice"
    assert tool_entry["raw_arguments"] == Jason.encode!(%{"query" => sentinel})

    assert {:ok, :deleted} = OpenAgents.DataRights.delete(user, owner, conversation)

    assert Repo.get(OpenAgents.Conversations.Visitor, owner.id) == nil
    assert Repo.get(OpenAgents.Voice.Session, stored.id) == nil
    assert Repo.get(OpenAgents.Voice.ToolStep, tool_step.id) == nil
    assert Conversations.get_conversation_for_user(user) == nil
    assert Repo.get(OpenAgents.Accounts.User, user.id)
  end

  defp enabled_voice do
    [
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    ]
  end

  defp await_session_status(session_id, expected_status, attempts \\ 100)

  defp await_session_status(session_id, expected_status, attempts) when attempts > 0 do
    session = Voice.get_session!(session_id)

    if session.status == expected_status do
      session
    else
      receive do
      after
        10 -> await_session_status(session_id, expected_status, attempts - 1)
      end
    end
  end

  defp await_session_status(session_id, expected_status, 0) do
    session = Voice.get_session!(session_id)

    flunk("voice session #{session_id} remained #{session.status}; expected #{expected_status}")
  end

  defp await_event_kinds(session_id, expected_kinds, attempts \\ 100)

  defp await_event_kinds(session_id, expected_kinds, attempts) when attempts > 0 do
    session = Voice.get_session!(session_id)
    actual_kinds = Enum.map(Voice.list_events(session), & &1.kind)

    if actual_kinds == expected_kinds do
      session
    else
      receive do
      after
        10 -> await_event_kinds(session_id, expected_kinds, attempts - 1)
      end
    end
  end

  defp await_event_kinds(session_id, expected_kinds, 0) do
    session = Voice.get_session!(session_id)
    actual_kinds = Enum.map(Voice.list_events(session), & &1.kind)

    flunk(
      "voice session #{session_id} events were #{inspect(actual_kinds)}; " <>
        "expected #{inspect(expected_kinds)}"
    )
  end

  defp prepare_response(sideband, session, item_id, content) do
    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :user_transcript_final,
        provider_event_id: "evt-user-#{item_id}",
        payload: %{"item_id" => item_id, "response_id" => nil, "content" => content}
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "response.create",
                      "response" => %{"instructions" => instructions, "tool_choice" => "auto"}
                    }}

    assert instructions =~ "<protected_identity"
    _state = :sys.get_state(VoiceSessions.whereis(session.id))
    :ok
  end

  defp start_response(sideband, session, item_id, content, response_id) do
    prepare_response(sideband, session, item_id, content)

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-start-#{response_id}",
        payload: %{"response_id" => response_id}
      }
    })

    _responding = await_session_status(session.id, "responding")
    :ok
  end

  defp request_tool(
         sideband,
         session,
         response_id,
         call_id,
         item_id,
         tool_name,
         arguments
       ) do
    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :tool_call_requested,
        provider_event_id: "evt-tool-#{call_id}",
        payload: %{
          "response_id" => response_id,
          "item_id" => item_id,
          "call_id" => call_id,
          "tool_name" => tool_name,
          "raw_arguments" => Jason.encode!(arguments)
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-#{response_id}",
        payload: %{"response_id" => response_id, "status" => "completed", "usage" => %{}}
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{
                        "type" => "function_call_output",
                        "call_id" => ^call_id,
                        "output" => encoded_output
                      }
                    }},
                   1_000

    assert_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "auto"}}},
                   1_000

    Jason.decode!(encoded_output)
  end

  defp finish_response_with_usage(sideband, session, response_id, item_id, usage) do
    prepare_response(sideband, session, item_id, "Say a full sentence.")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-start-#{response_id}",
        payload: %{"response_id" => response_id}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-transcript-#{response_id}",
        payload: %{
          "response_id" => response_id,
          "item_id" => "item-assistant-#{response_id}",
          "content" => "A complete spoken sentence."
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-#{response_id}",
        payload: %{"response_id" => response_id, "status" => "completed", "usage" => usage}
      }
    })

    _listening = await_session_status(session.id, "listening")
    _state = :sys.get_state(VoiceSessions.whereis(session.id))
    :ok
  end

  defp finish_response(sideband, session, response_id, item_id, content) do
    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-start-#{response_id}",
        payload: %{"response_id" => response_id}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-transcript-#{response_id}",
        payload: %{"response_id" => response_id, "item_id" => item_id, "content" => content}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-#{response_id}",
        payload: %{"response_id" => response_id, "status" => "completed", "usage" => %{}}
      }
    })

    _listening = await_session_status(session.id, "listening")
    _state = :sys.get_state(VoiceSessions.whereis(session.id))
    :ok
  end

  test "warns at 80% of the session budget and ends with a visible reason at the ceiling" do
    previous_budget = Application.fetch_env!(:openagents, :voice_maximum_session_tokens)
    Application.put_env(:openagents, :voice_maximum_session_tokens, 1_000)

    on_exit(fn ->
      Application.put_env(:openagents, :voice_maximum_session_tokens, previous_budget)
    end)

    {:ok, conversation} = Conversations.ensure_conversation("voice-budget-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=budget-offer",
               String.duplicate("b", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    finish_response_with_usage(sideband, session, "response-warm", "item-user-warm", %{
      "input_tokens" => 700,
      "output_tokens" => 150,
      "total_tokens" => 850
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{"role" => "system", "content" => [%{"text" => warning}]}
                    }},
                   1_000

    assert warning =~ "80%"

    start_response(sideband, session, "item-user-over", "Keep going.", "response-over")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-response-over",
        payload: %{
          "response_id" => "response-over",
          "status" => "completed",
          "usage" => %{"input_tokens" => 180, "output_tokens" => 20, "total_tokens" => 200}
        }
      }
    })

    ended = await_session_status(session.id, "ended")
    assert ended.termination_reason == "usage_budget_reached"
  end

  test "the tool-call limit refuses the next call and drives one tool-free report" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-tool-limit-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=tool-limit-offer",
               String.duplicate("c", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(sideband, session, "item-user-limit", "Run every lookaround.", "resp-1")

    for index <- 1..8 do
      decoded =
        request_tool(
          sideband,
          session,
          "resp-#{index}",
          "call-#{index}",
          "item-call-#{index}",
          "memory_list",
          %{"category" => "preference", "first" => 10}
        )

      assert decoded["output"]["status"] == "succeeded"

      send(sideband, {
        :provider_event,
        session,
        %ProviderEvent{
          kind: :response_started,
          provider_event_id: "evt-start-resp-#{index + 1}",
          payload: %{"response_id" => "resp-#{index + 1}"}
        }
      })

      _responding = await_session_status(session.id, "responding")
    end

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :tool_call_requested,
        provider_event_id: "evt-tool-call-9",
        payload: %{
          "response_id" => "resp-9",
          "item_id" => "item-call-9",
          "call_id" => "call-9",
          "tool_name" => "memory_list",
          "raw_arguments" => "{}"
        }
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{
                        "type" => "function_call_output",
                        "call_id" => "call-9",
                        "output" => refusal_output
                      }
                    }},
                   1_000

    refusal = Jason.decode!(refusal_output)
    assert refusal["output"]["status"] == "refused"
    assert refusal["output"]["error"]["code"] == "tool_call_limit_reached"

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-resp-9",
        payload: %{"response_id" => "resp-9", "status" => "completed", "usage" => %{}}
      }
    })

    assert_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "none"}}},
                   1_000

    alive = Voice.get_session!(session.id)
    assert alive.status in ~w(listening responding)
    assert is_pid(VoiceSessions.whereis(session.id))

    assert {:ok, _ended} = VoiceSessions.end_session(alive)
  end

  test "barge-in truncates unheard speech and keeps the interrupted promise as labeled evidence" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-truncate-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=truncate-offer",
               String.duplicate("d", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(sideband, session, "item-user-truncate", "Do the lookarounds.", "resp-cut")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_delta,
        provider_event_id: nil,
        payload: %{"item_id" => "item-assistant-cut", "delta" => "I will take three more looks"}
      }
    })

    _state = :sys.get_state(VoiceSessions.whereis(session.id))

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :speech_started,
        provider_event_id: "evt-cut-speech",
        payload: %{"item_id" => "item-user-cut"}
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.truncate",
                      "item_id" => "item-assistant-cut",
                      "content_index" => 0,
                      "audio_end_ms" => audio_end_ms
                    }},
                   1_000

    assert is_integer(audio_end_ms) and audio_end_ms >= 0
    assert_receive {:sideband_event_sent, %{"type" => "response.cancel"}}, 1_000

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-cut-final",
        payload: %{
          "response_id" => "resp-cut",
          "item_id" => "item-assistant-cut",
          "content" => "I will take three more looks"
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-cut-done",
        payload: %{"response_id" => "resp-cut", "status" => "cancelled", "usage" => %{}}
      }
    })

    _state = :sys.get_state(VoiceSessions.whereis(session.id))

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :user_transcript_final,
        provider_event_id: "evt-user-after-cut",
        payload: %{
          "item_id" => "item-user-cut",
          "response_id" => nil,
          "content" => "Continue where you stopped."
        }
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "response.create",
                      "response" => %{"instructions" => instructions}
                    }},
                   1_000

    assert instructions =~ "assistant (interrupted mid-speech; not a completed claim)"
    assert instructions =~ "I will take three more looks"

    assert {:ok, _ended} = VoiceSessions.end_session(Voice.get_session!(session.id))
  end

  test "a new voice generation is admitted with prior conversation and tool evidence" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-carryover-browser")

    assert {:ok, first_session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=carryover-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(sideband, first_session, "item-user-carry", "List my memory.", "resp-carry")

    tool_output =
      request_tool(
        sideband,
        first_session,
        "resp-carry",
        "call-carry",
        "item-call-carry",
        "memory_list",
        %{"category" => "preference", "first" => 10}
      )

    assert tool_output["output"]["status"] == "succeeded"

    finish_response(
      sideband,
      first_session,
      "resp-carry-answer",
      "item-assistant-carry",
      "Your memory list is empty so far."
    )

    assert {:ok, _ended} = VoiceSessions.end_session(Voice.get_session!(first_session.id))

    Application.put_env(
      :openagents,
      :voice_call_test_result,
      {:ok,
       %OpenAgents.Voice.CallAdmission{
         provider_session_id: "rtc_test_carryover",
         answer_sdp: "v=0\r\no=test-answer"
       }}
    )

    on_exit(fn -> Application.delete_env(:openagents, :voice_call_test_result) end)

    assert {:ok, second_session, _second_admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=carryover-offer-2",
               String.duplicate("b", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert second_session.generation == first_session.generation + 1
    assert second_session.instructions =~ "Your memory list is empty so far."
    assert second_session.instructions =~ "tool memory_list succeeded"

    assert {:ok, _second_ended} = VoiceSessions.end_session(Voice.get_session!(second_session.id))
  end

  test "a barge-in during a tool call still delivers the terminal function_call_output" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-orphan-tool-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=orphan-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(sideband, session, "item-user-orphan", "List my memory.", "resp-orphan")

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :tool_call_requested,
        provider_event_id: "evt-orphan-tool",
        payload: %{
          "response_id" => "resp-orphan",
          "item_id" => "item-orphan-call",
          "call_id" => "call-orphan",
          "tool_name" => "memory_list",
          "raw_arguments" => "{}"
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :speech_started,
        provider_event_id: "evt-orphan-speech",
        payload: %{"item_id" => "item-user-orphan-2"}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-orphan-done",
        payload: %{"response_id" => "resp-orphan", "status" => "cancelled", "usage" => %{}}
      }
    })

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{
                        "type" => "function_call_output",
                        "call_id" => "call-orphan",
                        "output" => orphan_output
                      }
                    }},
                   2_000

    decoded = Jason.decode!(orphan_output)

    assert decoded["output"]["status"] in ~w(succeeded failed refused cancelled unavailable interrupted)

    refute_receive {:sideband_event_sent, %{"type" => "response.create"}}, 200

    assert {:ok, _ended} = VoiceSessions.end_session(Voice.get_session!(session.id))
  end

  test "context compaction summarizes, persists, prunes old items, and keeps the session alive" do
    previous_threshold =
      Application.fetch_env!(:openagents, :voice_compaction_input_token_threshold)

    Application.put_env(:openagents, :voice_compaction_input_token_threshold, 500)

    on_exit(fn ->
      Application.put_env(
        :openagents,
        :voice_compaction_input_token_threshold,
        previous_threshold
      )
    end)

    {:ok, conversation} = Conversations.ensure_conversation("voice-compaction-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=compaction-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    # Three small responses accumulate six known provider items under the
    # threshold and must not trigger compaction.
    for index <- 1..3 do
      finish_response_with_usage(
        sideband,
        session,
        "resp-small-#{index}",
        "item-user-small-#{index}",
        %{"input_tokens" => 100, "output_tokens" => 10, "total_tokens" => 110}
      )
    end

    refute_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "none"}}},
                   200

    # The fourth response reports input at the threshold: one text-only,
    # tool-free compaction response is driven under the same frozen context.
    finish_response_with_usage(
      sideband,
      session,
      "resp-big",
      "item-user-big",
      %{"input_tokens" => 600, "output_tokens" => 40, "total_tokens" => 640}
    )

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "response.create",
                      "response" => %{
                        "tool_choice" => "none",
                        "output_modalities" => ["text"],
                        "instructions" => compaction_instructions,
                        "max_output_tokens" => compaction_output_tokens
                      }
                    }},
                   1_000

    assert compaction_instructions =~ "Host compaction request"
    assert compaction_instructions =~ "exact"
    assert is_integer(compaction_output_tokens)

    summary =
      "Completed three lookarounds; exact value 42 found in repo sarah; " <>
        "next action: report the concise findings."

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_started,
        provider_event_id: "evt-start-resp-compact",
        payload: %{"response_id" => "resp-compact"}
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :assistant_transcript_final,
        provider_event_id: "evt-transcript-resp-compact",
        payload: %{
          "response_id" => "resp-compact",
          "item_id" => "item-assistant-compact",
          "content" => summary
        }
      }
    })

    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :response_completed,
        provider_event_id: "evt-done-resp-compact",
        payload: %{
          "response_id" => "resp-compact",
          "status" => "completed",
          "usage" => %{"input_tokens" => 650, "output_tokens" => 60, "total_tokens" => 710}
        }
      }
    })

    # Only the oldest known items beyond the retained window are deleted, in
    # order, and exactly one bounded system summary item is injected.
    assert_receive {:sideband_event_sent,
                    %{"type" => "conversation.item.delete", "item_id" => "item-user-small-1"}},
                   1_000

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.delete",
                      "item_id" => "item-assistant-resp-small-1"
                    }},
                   1_000

    assert_receive {:sideband_event_sent,
                    %{"type" => "conversation.item.delete", "item_id" => "item-user-small-2"}},
                   1_000

    assert_receive {:sideband_event_sent,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{"role" => "system", "content" => [%{"text" => summary_item}]}
                    }},
                   1_000

    assert summary_item == "Earlier conversation compacted. Summary: " <> summary

    refute_receive {:sideband_event_sent, %{"type" => "conversation.item.delete"}}, 100

    process = VoiceSessions.whereis(session.id)
    assert is_pid(process)
    state = :sys.get_state(process)
    assert state.compaction == nil

    stored = Voice.get_session!(session.id)
    assert stored.compaction_summary == summary
    assert stored.compaction_count == 1
    assert stored.status == "listening"

    # The compaction response itself cannot re-trigger, and the cooldown holds
    # even when the next response is still past the threshold.
    finish_response_with_usage(
      sideband,
      session,
      "resp-after",
      "item-user-after",
      %{"input_tokens" => 600, "output_tokens" => 10, "total_tokens" => 610}
    )

    refute_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "none"}}},
                   200

    # Post-compaction simulated input drops back under the threshold.
    finish_response_with_usage(
      sideband,
      session,
      "resp-flat",
      "item-user-flat",
      %{"input_tokens" => 120, "output_tokens" => 10, "total_tokens" => 130}
    )

    state = :sys.get_state(VoiceSessions.whereis(session.id))
    assert state.last_response_input_tokens == 120

    assert {:ok, _ended} = VoiceSessions.end_session(Voice.get_session!(session.id))
  end

  test "compaction does not trigger below the input-token threshold" do
    {:ok, conversation} = Conversations.ensure_conversation("voice-compaction-guard-browser")

    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=compaction-guard-offer",
               String.duplicate("b", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    finish_response_with_usage(
      sideband,
      session,
      "resp-under",
      "item-user-under",
      %{"input_tokens" => 15_999, "output_tokens" => 10, "total_tokens" => 16_009}
    )

    refute_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "none"}}},
                   200

    state = :sys.get_state(VoiceSessions.whereis(session.id))
    assert state.compaction == nil
    assert state.last_response_input_tokens == 15_999
    assert Voice.get_session!(session.id).compaction_count == 0

    finish_response_with_usage(
      sideband,
      session,
      "resp-at",
      "item-user-at",
      %{"input_tokens" => 16_000, "output_tokens" => 10, "total_tokens" => 16_010}
    )

    assert_receive {:sideband_event_sent,
                    %{"type" => "response.create", "response" => %{"tool_choice" => "none"}}},
                   1_000

    assert {:ok, _ended} = VoiceSessions.end_session(Voice.get_session!(session.id))
  end
end
