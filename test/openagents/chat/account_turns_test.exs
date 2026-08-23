defmodule OpenAgents.Chat.AccountTurnsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Chat.AccountTurns
  alias OpenAgents.Chat.OpenRouter.ToolRuntime
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Tools.{AdmittedCatalog, OwnerContext, Registry}

  test "an operator can retry the provider failures a retry can fix" do
    for code <- ~w(rate_limited service_unavailable stream_interrupted invalid_response
                   provider_unavailable server_error) do
      assert AccountTurns.retryable_error_code?(code)
    end

    refute AccountTurns.retryable_error_code?("missing_api_key")
    refute AccountTurns.retryable_error_code?(nil)
  end

  test "the API turn names the conversation's visitor, so its tools reach the account" do
    # The regression this guards: the tool context carried `user.id` as
    # `owner_visitor_id`. A User id is not a Visitor id, so `OwnerContext`
    # read back no row and every owner-requiring tool refused a signed-in
    # caller with `owner_not_signed_in`. The value looked plausible and failed
    # somewhere else, which is why it survived. Assert on the resolution, not
    # on the shape of the id.
    user = repository_user_fixture("account-chat-owner-identity")
    test_process = self()

    streamer = fn _request, _callback, options ->
      send(test_process, {:tool_context, Keyword.fetch!(options, :tool_context)})
      {:ok, %{"assistant_content" => "Done.", "assistant_message_id" => "response-1"}}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "What can you do?",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    assert_receive {:tool_context, tool_context}

    visitor = Repo.get_by!(Visitor, user_id: user.id)
    assert tool_context.owner_visitor_id == visitor.id
    assert tool_context.owner_user_id == user.id
    refute tool_context.owner_visitor_id == user.id

    assert {:ok, runtime} = ToolRuntime.capture(tool_context: tool_context)
    assert {:ok, resolved} = OwnerContext.resolve(runtime.execution_context)
    assert resolved.id == user.id
  end

  test "a tool the API caller can use now runs for them" do
    # The acceptance criterion, end to end: the same context the turn hands the
    # provider executes an owner-requiring tool and succeeds. Before the fix
    # this returned status "failed" with code "owner_not_signed_in".
    user = repository_user_fixture("account-chat-tool-succeeds")
    test_process = self()

    streamer = fn _request, _callback, options ->
      send(test_process, {:tool_context, Keyword.fetch!(options, :tool_context)})
      {:ok, %{"assistant_content" => "Done.", "assistant_message_id" => "response-1"}}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "What computers do I have?",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    assert_receive {:tool_context, tool_context}
    assert {:ok, runtime} = ToolRuntime.capture(tool_context: tool_context)

    assert {:ok, outcome} =
             ToolRuntime.run(runtime, "call-computer-list", "computer_list", "{}")

    assert outcome["status"] == "succeeded"
    assert outcome["error"] == nil
    assert outcome["result"]["schema"] == "sarah.computer_list_result.v1"
  end

  test "the API turn offers the tools the browser offers the same account" do
    user = repository_user_fixture("account-chat-tool-parity")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)
    intent = "look up why my last delegation failed"
    test_process = self()

    streamer = fn _request, _callback, options ->
      send(test_process, {:tool_context, Keyword.fetch!(options, :tool_context)})
      {:ok, %{"assistant_content" => "Done.", "assistant_message_id" => "response-1"}}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, intent, subscriber: self(), streamer: streamer)

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    assert_receive {:tool_context, tool_context}

    assert {:ok, runtime} = ToolRuntime.capture(tool_context: tool_context)
    api_names = runtime |> ToolRuntime.provider_definitions(intent) |> Enum.map(& &1["name"])

    browser_names =
      runtime.snapshot
      |> AdmittedCatalog.provider_definitions(
        OpenAgents.Tools.ConversationExecutionContext.build(%{
          surface: "text",
          conversation_id: conversation.id,
          owner_visitor_id: owner.id,
          owner_user_id: owner.user_id,
          module_registry_snapshot: runtime.snapshot
        }),
        intent
      )
      |> Enum.map(& &1.name)

    assert Enum.sort(api_names) == Enum.sort(browser_names)
    assert "incident_lookup" in api_names
    assert Registry.current!().digest == runtime.snapshot.digest
  end

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
        {:tool_call_completed,
         %{
           "call_id" => "call-1",
           "output" =>
             Jason.encode!(%{
               "schema" => "sarah.tool_outcome.v1",
               "status" => "succeeded",
               "result" => %{"content" => "OpenAgents"},
               "error" => nil,
               "workspace" => %{
                 "type" => "forge_worktree",
                 "path" => "/private/var/lib/openagents/workspaces/openagents.com"
               },
               "target_receipt_refs" => ["receipt:forge:abc123"],
               "started_at" => "2026-08-22T19:43:28.000Z",
               "completed_at" => "2026-08-22T19:43:28.125Z"
             })
         }}
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

    assert %{
             "status" => "running",
             "state" => "input-available"
           } = Enum.at(events, 2)["tool_call"]

    assert %{
             "status" => "succeeded",
             "state" => "output-available",
             "duration_ms" => 125,
             "workspace" => %{"path" => "openagents.com"},
             "receipt_refs" => ["receipt:forge:abc123"],
             "error" => nil
           } = Enum.at(events, 3)["tool_call"]

    assert [user_message, assistant_message] = AccountTurns.list_messages(user)
    assert user_message.content == "Read the README."
    assert assistant_message.content == "The repository is available."
    assert assistant_message.history?

    assert [
             %{
               name: "read_repository_file",
               state: "output-available",
               status: "succeeded",
               duration_ms: 125,
               workspace_label: "openagents.com",
               receipt_refs: ["receipt:forge:abc123"]
             }
           ] =
             assistant_message.tool_calls

    refute inspect(events) =~ "/private/var/lib/openagents"
    refute inspect(assistant_message) =~ "/private/var/lib/openagents"

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

  test "projects typed tool errors without losing lifecycle order" do
    user = repository_user_fixture("account-chat-tool-error")

    streamer = fn _request, callback, _options ->
      callback.(
        {:tool_call_started,
         %{
           "call_id" => "call-edit",
           "name" => "edit",
           "arguments" => ~s({"path":"README.md"})
         }}
      )

      callback.(
        {:tool_call_failed,
         %{
           "call_id" => "call-edit",
           "output" => %{
             "schema" => "sarah.tool_outcome.v1",
             "status" => "failed",
             "error" => %{
               "code" => "workspace_read_only",
               "message" => "The workspace is read-only."
             },
             "workspace" => %{
               "type" => "forge_worktree",
               "path" => "/private/var/lib/openagents/workspaces/repo"
             },
             "started_at" => "2026-08-22T19:43:28.000Z",
             "completed_at" => "2026-08-22T19:43:28.004Z"
           }
         }}
      )

      {:ok, %{"assistant_content" => "I could not edit that file."}}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Edit the README.", subscriber: self(), streamer: streamer)

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}

    assert Enum.map(AccountTurns.list_events(user), & &1["type"]) == [
             "user_message",
             "tool_call_started",
             "tool_call_failed",
             "response_completed"
           ]

    failed = Enum.at(AccountTurns.list_events(user), 2)["tool_call"]
    assert failed["status"] == "failed"
    assert failed["state"] == "output-error"
    assert failed["duration_ms"] == 4

    assert failed["error"] == %{
             "code" => "workspace_read_only",
             "message" => "The workspace is read-only."
           }
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

  test "a backend replays only the history it wrote" do
    # An OpenRouter Responses output list is not a Gemini turn. Handing one
    # provider another's transcript shape is a request the provider refuses, so
    # switching backends starts from the turns that backend actually produced.
    user = repository_user_fixture("account-chat-backend-history")
    test_process = self()

    recorder = fn label ->
      fn request, _callback, _options ->
        send(test_process, {:request, label, request})
        {:ok, %{"assistant_content" => "Answered by #{label}."}}
      end
    end

    assert {:ok, %{"id" => first_id, "model" => "ox-alpha"}} =
             AccountTurns.submit(user, "First.", subscriber: self(), streamer: recorder.("ox"))

    assert_receive {:request, "ox", _first_request}
    assert_receive {:account_chat_completed, ^first_id, {:ok, _completion}}

    assert {:ok, %{"id" => second_id, "model" => "gemini-3.7-flash"}} =
             AccountTurns.submit(user, "Second.",
               subscriber: self(),
               backend: "gemini-3.7-flash",
               streamer: recorder.("gemini")
             )

    assert_receive {:request, "gemini", gemini_request}
    assert_receive {:account_chat_completed, ^second_id, {:ok, _completion}}

    # Gemini sees its own first turn and nothing from the Ox Alpha lane.
    assert gemini_request["messages"] == [%{"role" => "user", "content" => "Second."}]
    assert gemini_request["model"] == "gemini-3.7-flash"

    assert {:ok, %{"id" => third_id}} =
             AccountTurns.submit(user, "Third.", subscriber: self(), streamer: recorder.("ox"))

    assert_receive {:request, "ox", ox_request}
    assert_receive {:account_chat_completed, ^third_id, {:ok, _completion}}

    assert Enum.map(ox_request["messages"], & &1["content"]) == [
             "First.",
             "Answered by ox.",
             "Third."
           ]
  end

  test "a failure names the backend that failed" do
    user = repository_user_fixture("account-chat-backend-error")
    streamer = fn _request, _callback, _options -> {:error, :rate_limited} end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Hello.",
               subscriber: self(),
               backend: "gemini-3.7-flash",
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:error, :rate_limited}}

    assistant = AccountTurns.list_messages(user) |> List.last()
    assert assistant.error =~ "Gemini 3.7 Flash"
    refute assistant.error =~ "OpenRouter"
  end

  test "an unsupported backend never creates a turn" do
    user = repository_user_fixture("account-chat-backend-unknown")

    assert {:error, :unsupported_backend} =
             AccountTurns.submit(user, "Hello.", backend: "gpt-4")

    assert AccountTurns.list_messages(user) == []
  end
end
