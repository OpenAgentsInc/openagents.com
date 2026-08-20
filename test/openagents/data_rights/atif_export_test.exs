defmodule OpenAgents.DataRights.AtifExportTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.DataRights.AtifExport
  alias OpenAgents.Voice.ProviderEvent
  alias OpenAgents.{Conversations, Turns, Voice, VoiceSessions}

  setup do
    previous_voice = Application.fetch_env!(:openagents, :voice)
    Application.put_env(:openagents, :voice, enabled_voice())
    Application.put_env(:openagents, :test_tool_observer, self())
    Application.put_env(:openagents, :voice_call_test_observer, self())
    Application.put_env(:openagents, :voice_sideband_test_observer, self())

    on_exit(fn ->
      Application.put_env(:openagents, :voice, previous_voice)
      Application.delete_env(:openagents, :test_tool_observer)
      Application.delete_env(:openagents, :voice_call_test_observer)
      Application.delete_env(:openagents, :voice_sideband_test_observer)
    end)

    :ok
  end

  test "builds one valid chronological ATIF v1.7 trajectory across both surfaces" do
    user = OpenAgentsWeb.ConnCase.github_user("atif-builder-owner")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    # A typed turn whose provider requests one tool call and then answers.
    {:ok, %{turn: turn}} = Conversations.create_turn(conversation, "[tool-loop]")
    {:ok, turn_pid} = Turns.start(turn.id)
    turn_monitor = Process.monitor(turn_pid)
    assert_receive {:DOWN, ^turn_monitor, :process, ^turn_pid, :normal}, 2_000
    assert_receive {:test_tool_executed, _tool_pid, "quartz", _scope_ref}

    completed_turn = Conversations.get_turn!(turn.id)
    assert completed_turn.status == "completed"
    assert {:ok, turn_receipt} = Conversations.get_turn_receipt(completed_turn)

    # A voice generation with one governed tool-only response and one spoken
    # response interrupted mid-speech.
    assert {:ok, session, _admission} =
             VoiceSessions.connect(
               conversation,
               "v=0\r\no=atif-offer",
               String.duplicate("a", 64),
               OpenAgents.Voice.Config.current!()
             )

    assert_receive {:sideband_started, sideband, _sideband_session}

    start_response(sideband, session, "item-user-list", "List my memory please.", "resp-list")

    list_output =
      request_tool(
        sideband,
        session,
        "resp-list",
        "call-list",
        "item-call-list",
        "memory_list",
        %{"category" => "preference", "first" => 10}
      )

    assert list_output["output"]["status"] == "succeeded"

    interrupt_response(
      sideband,
      session,
      "resp-interrupted",
      "item-assistant-interrupted",
      "I will now walk through every memory in",
      %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    )

    stored_session = Voice.get_session!(session.id)
    assert {:ok, _ended} = VoiceSessions.end_session(stored_session)

    assert {:ok, export} = AtifExport.build(user, owner, conversation)

    assert export["schema_version"] == "ATIF-v1.7"
    assert export["session_id"] == conversation.id
    assert export["trajectory_id"] == conversation.id
    assert is_binary(export["notes"]) and export["notes"] =~ "digest"

    agent = export["agent"]
    assert agent["name"] == "simply-sarah"
    assert is_binary(agent["version"]) and agent["version"] != ""
    assert agent["model_name"] == Application.fetch_env!(:openagents, :openai_model)
    assert [_definition | _rest] = agent["tool_definitions"]

    assert Enum.all?(agent["tool_definitions"], fn definition ->
             definition["type"] == "function" and is_binary(definition["function"]["name"]) and
               is_map(definition["function"]["parameters"])
           end)

    steps = export["steps"]

    # Validator rule: step_ids are sequential from 1.
    assert Enum.map(steps, & &1["step_id"]) == Enum.to_list(1..length(steps))
    assert Enum.all?(steps, &(&1["source"] in ["user", "agent", "system"]))

    assert Enum.all?(steps, fn step ->
             match?({:ok, _at, _offset}, DateTime.from_iso8601(step["timestamp"]))
           end)

    # Validator rule: every observation result correlates to a tool_call_id
    # declared on the same step, and non-agent steps carry no tool fields.
    assert Enum.all?(steps, fn step ->
             call_ids = step |> Map.get("tool_calls", []) |> Enum.map(& &1["tool_call_id"])
             results = get_in(step, ["observation", "results"]) || []

             Enum.all?(results, &(&1["source_call_id"] in call_ids)) and
               (step["source"] == "agent" or
                  (call_ids == [] and results == [] and not Map.has_key?(step, "metrics")))
           end)

    # The conversation opens with Sarah's seeded greeting, then the two
    # surfaces in the order they actually happened.
    [greeting, text_user, text_agent, voice_user, voice_tool, voice_interrupted] = steps

    assert greeting["source"] == "agent"
    assert greeting["extra"]["surface"] == "text"

    assert %{"source" => "user", "message" => "[tool-loop]", "extra" => %{"surface" => "text"}} =
             text_user

    assert text_agent["source"] == "agent"
    assert text_agent["message"] == "Known tool outcome: succeeded."
    assert text_agent["extra"]["surface"] == "text"
    assert text_agent["extra"]["turn_status"] == "completed"
    assert text_agent["model_name"] == turn_receipt.model_id
    assert text_agent["llm_call_count"] == 2

    assert [tool_call] = text_agent["tool_calls"]
    assert tool_call["tool_call_id"] == "call-tool-1"
    assert tool_call["function_name"] == "recall_messages"
    assert tool_call["arguments"] == %{"query" => "quartz"}
    assert tool_call["extra"]["argument_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    assert tool_call["extra"]["status"] == "succeeded"
    assert is_binary(tool_call["extra"]["executor_disclosure"])

    assert [observed] = text_agent["observation"]["results"]
    assert observed["source_call_id"] == "call-tool-1"
    assert observed["content"] =~ "Found quartz in this conversation."
    assert observed["extra"]["status"] == "succeeded"

    assert text_agent["metrics"] == %{
             "prompt_tokens" => turn_receipt.usage["input_tokens"],
             "completion_tokens" => turn_receipt.usage["output_tokens"]
           }

    assert %{"source" => "user", "message" => "List my memory please."} = voice_user
    assert voice_user["extra"]["surface"] == "voice"

    # The tool-only Realtime response has no assistant message, so its durable
    # tool evidence rides an agent step with an honestly empty message.
    assert voice_tool["source"] == "agent"
    assert voice_tool["message"] == ""
    assert voice_tool["extra"]["surface"] == "voice"
    assert voice_tool["extra"]["tool_only_response"] == true
    assert [voice_call] = voice_tool["tool_calls"]
    assert voice_call["tool_call_id"] == "call-list"
    assert voice_call["function_name"] == "memory_list"
    assert voice_call["arguments"] == %{"category" => "preference", "first" => 10}
    assert voice_call["extra"]["argument_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    assert [voice_observed] = voice_tool["observation"]["results"]
    assert voice_observed["source_call_id"] == "call-list"
    assert voice_observed["extra"]["status"] == "succeeded"

    # The interrupted spoken step keeps its text but is labeled, never a
    # completed claim (VOICE-009's honesty carried into the export).
    assert voice_interrupted["source"] == "agent"
    assert voice_interrupted["message"] == "I will now walk through every memory in"
    assert voice_interrupted["extra"]["surface"] == "voice"
    assert voice_interrupted["extra"]["interrupted"] == true
    assert voice_interrupted["extra"]["response_status"] == "interrupted"
    assert voice_interrupted["metrics"]["prompt_tokens"] == 10
    assert voice_interrupted["metrics"]["completion_tokens"] == 5
    assert voice_interrupted["metrics"]["cost_usd"] > 0

    session_usage = Voice.get_session!(session.id).usage
    final_metrics = export["final_metrics"]

    assert final_metrics["total_prompt_tokens"] ==
             turn_receipt.usage["input_tokens"] + session_usage["input_tokens"]

    assert final_metrics["total_completion_tokens"] ==
             turn_receipt.usage["output_tokens"] + session_usage["output_tokens"]

    assert final_metrics["total_cost_usd"] ==
             session_usage["estimated_cost_microusd"] / 1_000_000

    assert final_metrics["total_steps"] == length(steps)

    assert export["extra"]["messages_truncated"] == false
    assert export["extra"]["voice_sessions_truncated"] == false

    # Raw tool arguments are durable since issue #72, so the export carries
    # them verbatim for training-grade trajectories.
    assert Jason.encode!(export) =~ ~s("query":"quartz")
  end

  test "oversized tool results export as valid, bounded JSON content" do
    huge = String.duplicate("x", 20_000)
    # bound_json trims the longest string values rather than cutting the
    # encoded document mid-string, so consumers can always parse the content.
    encoded = %{"schema" => "test.v1", "output" => huge, "status" => "succeeded"}
    content = AtifExport.bound_json(encoded)
    assert byte_size(content) <= 8_192
    decoded = Jason.decode!(content)
    assert decoded["schema"] == "test.v1"
    assert decoded["status"] == "succeeded"
    assert decoded["output"] =~ "…[truncated by export bound]"
  end

  test "refuses a visitor root the user does not own" do
    user = OpenAgentsWeb.ConnCase.github_user("atif-builder-owner-a")
    other_user = OpenAgentsWeb.ConnCase.github_user("atif-builder-owner-b")
    {:ok, _conversation} = Conversations.ensure_conversation(user)
    {:ok, other_conversation} = Conversations.ensure_conversation(other_user)
    other_owner = Conversations.get_conversation_owner!(other_conversation)

    assert_raise FunctionClauseError, fn ->
      AtifExport.build(user, other_owner, other_conversation)
    end
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

  defp start_response(sideband, session, item_id, content, response_id) do
    send(sideband, {
      :provider_event,
      session,
      %ProviderEvent{
        kind: :user_transcript_final,
        provider_event_id: "evt-user-#{item_id}",
        payload: %{"item_id" => item_id, "response_id" => nil, "content" => content}
      }
    })

    assert_receive {:sideband_event_sent, %{"type" => "response.create"}}, 1_000

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

  defp request_tool(sideband, session, response_id, call_id, item_id, tool_name, arguments) do
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

    assert_receive {:sideband_event_sent, %{"type" => "response.create"}}, 1_000

    Jason.decode!(encoded_output)
  end

  defp interrupt_response(sideband, session, response_id, item_id, content, usage) do
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
        payload: %{"response_id" => response_id, "status" => "cancelled", "usage" => usage}
      }
    })

    _listening = await_session_status(session.id, "listening")
    :ok
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
end
