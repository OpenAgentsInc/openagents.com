defmodule OpenAgents.Chat.AccountTurnsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Chat.AccountTurns

  test "submit journals the provider lifecycle and projects the same ordered messages" do
    user = repository_user_fixture("account-chat-journal")

    provider_output = [
      %{
        "type" => "reasoning",
        "id" => "reasoning-1",
        "encrypted_content" => "opaque",
        "summary" => [%{"type" => "summary_text", "text" => "Check the repository."}]
      },
      %{
        "type" => "function_call",
        "id" => "function-1",
        "call_id" => "call-1",
        "name" => "read_repository_file",
        "arguments" => ~s({"path":"README.md"}),
        "status" => "completed"
      },
      %{
        "type" => "message",
        "id" => "message-1",
        "role" => "assistant",
        "status" => "completed",
        "content" => [
          %{
            "type" => "output_text",
            "text" => "The repository is available.",
            "annotations" => []
          }
        ]
      }
    ]

    streamer = fn _request, callback, _options ->
      callback.({:reasoning_delta, "Check the repository."})

      callback.(
        {:tool_call_started,
         %{
           "call_id" => "call-1",
           "name" => "read_repository_file",
           "arguments" => ~s({"path":"README.md"})
         }}
      )

      callback.(
        {:tool_call_completed, %{"call_id" => "call-1", "output" => ~s({"content":"OpenAgents"})}}
      )

      callback.({:text_delta, "The repository is available."})

      {:ok,
       %{
         "assistant_content" => "The repository is available.",
         "assistant_message_id" => "response-1",
         "reasoning_summary" => "Check the repository.",
         "reasoning_items" => [%{"type" => "reasoning", "encrypted_content" => "opaque"}],
         "output" => provider_output
       }}
    end

    assert {:ok, %{"id" => run_id, "status" => "streaming"}} =
             AccountTurns.submit(user, "Read the README.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}

    events = AccountTurns.list_events(user)

    assert Enum.map(events, & &1["type"]) == [
             "user_message",
             "reasoning_delta",
             "tool_call_started",
             "tool_call_completed",
             "text_delta",
             "response_completed"
           ]

    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..6)
    assert get_in(List.last(events), ["payload", "reasoning_items"]) != nil

    assert [user_message, assistant_message] = AccountTurns.list_messages(user)
    assert user_message.content == "Read the README."
    assert assistant_message.content == "The repository is available."
    assert assistant_message.history?

    assert [%{name: "read_repository_file", state: "output-available"}] =
             assistant_message.tool_calls

    test_process = self()

    follow_up_streamer = fn request, _callback, _options ->
      send(test_process, {:provider_request, request})
      {:ok, %{"assistant_content" => "Continued."}}
    end

    assert {:ok, %{"id" => follow_up_run_id}} =
             AccountTurns.submit(user, "Continue.",
               subscriber: self(),
               streamer: follow_up_streamer
             )

    assert_receive {:provider_request, request}

    assert %{"role" => "assistant", "provider_output" => ^provider_output} =
             Enum.at(request["messages"], 1)

    assert_receive {:account_chat_completed, ^follow_up_run_id, {:ok, _completion}}
  end

  test "events are isolated by account" do
    user = repository_user_fixture("account-chat-owner")
    other_user = repository_user_fixture("account-chat-other")

    streamer = fn _request, _callback, _options ->
      {:ok, %{"assistant_content" => "Done."}}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Private message.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    assert AccountTurns.list_events(user) != []
    assert AccountTurns.list_events(other_user) == []
  end
end
