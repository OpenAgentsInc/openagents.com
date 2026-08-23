defmodule OpenAgentsWeb.ChatConsoleTest do
  @moduledoc """
  `/chat` is the operator-only Ox Alpha console.

  The gate is worth its own file because it fails in two quiet directions: a
  missing plug lets a signed-in non-operator read the page, and a missing
  on_mount hook lets a LiveView event run on a socket that never passed the
  gate. The turn states carry the rest of the file: an empty console, a turn in
  flight, a completed turn with the evidence the provider reported, a stopped
  turn, and a failed turn whose prompt survives.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.Chat.AccountTurns

  # The console streams through OpenRouter. These tests replace that function so
  # a turn reaches its states without a provider.
  defp stub_streamer(streamer) do
    Application.put_env(:openagents, :chat_console_streamer, streamer)
    on_exit(fn -> Application.delete_env(:openagents, :chat_console_streamer) end)
  end

  test "an anonymous request is sent home", %{conn: conn} do
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "a signed-in non-operator is sent home", %{conn: conn} do
    conn = log_in_github_user(conn, "not-an-operator")
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "an operator gets the empty console", %{conn: conn} do
    conn = log_in_admin_user(conn, "console-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-transcript")
    assert has_element?(view, "#chat-console-empty")
    assert has_element?(view, "#chat-console-model", "Ox Alpha")
    assert has_element?(view, "#chat-console-operator-notice", "Operator-only console")
    assert has_element?(view, "#chat-console-token-list", "No tokens yet")
    refute has_element?(view, "#chat-console-token-total")
    assert has_element?(view, "#chat-console-suggestions")
    assert has_element?(view, "#chat-console-suggestion-0")
    assert has_element?(view, ~s(a[href="/sarah"]))
    assert has_element?(view, ~s(#chat-console-form[data-submit-on-enter="true"]))
    assert has_element?(view, ~s(#chat-console-form[data-clear-event="chat-console:clear"]))
    assert has_element?(view, ~s(#chat_message[phx-mounted]))
    assert has_element?(view, ~s(#chat_reasoning[name="chat[reasoning]"]))
    assert has_element?(view, "#chat-console-submit")
  end

  test "a suggestion fills the composer", %{conn: conn} do
    conn = log_in_admin_user(conn, "console-suggestion-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    html = view |> element("#chat-console-suggestion-0") |> render_click()

    assert html =~ "Ox Alpha stress fleet measures"
  end

  test "a turn in flight can be stopped", %{conn: conn} do
    stub_streamer(fn _request, callback, _options ->
      callback.({:text_delta, "Working"})

      receive do
        :never -> {:ok, %{}}
      end
    end)

    conn = log_in_admin_user(conn, "console-streaming-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#chat-console-form", %{"chat" => %{"message" => "Stress the fleet."}})
    |> render_submit()

    assert has_element?(view, "#chat-console-streaming-assistant-message")
    assert has_element?(view, ~s(#chat-console-submit[aria-label="Stop response"]))

    view |> element("#chat-console-submit") |> render_click()

    refute has_element?(view, "#chat-console-streaming-assistant-message")
    assert has_element?(view, ~s([id^="chat-console-cancelled-"]), "You stopped this response")
  end

  test "a completed turn shows the evidence the provider reported", %{conn: conn} do
    key = "console-completed-operator"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)

    streamer = fn _request, callback, _options ->
      callback.({:text_delta, "The fleet is idle."})

      {:ok,
       %{
         "object" => "chat.completion",
         "model" => "stealth/ox-alpha",
         "assistant_content" => "The fleet is idle.",
         "provider" => "Stealth",
         "request_id" => "gen-123",
         "usage" => %{
           "prompt_tokens" => 24,
           "completion_tokens" => 8,
           "total_tokens" => 32,
           "completion_tokens_details" => %{"reasoning_tokens" => 3},
           "prompt_tokens_details" => %{"cached_tokens" => 4}
         }
       }}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Report the fleet.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    metadata = "#chat-console-response-metadata-#{run_id}"
    assert has_element?(view, metadata, "Ox Alpha")
    assert has_element?(view, metadata, "lane Stealth")
    assert has_element?(view, metadata, "request gen-123")
    assert has_element?(view, metadata, "ms")
    assert has_element?(view, "#chat-console-usage-#{run_id}", "Input 24")
    assert has_element?(view, "#chat-console-usage-#{run_id}", "Output 8")
    assert has_element?(view, "#chat-console-usage-#{run_id}", "Reasoning 3")
    assert has_element?(view, "#chat-console-usage-#{run_id}", "Cached 4")
    assert has_element?(view, "#chat-console-token-input", "24")
    assert has_element?(view, "#chat-console-token-output", "8")
    assert has_element?(view, "#chat-console-token-reasoning", "3")
    assert has_element?(view, "#chat-console-token-cached", "4")
    assert has_element?(view, "#chat-console-token-total", "32")
    refute has_element?(view, "#chat-console-evidence-#{run_id}")
  end

  test "a turn that reasoned without a reasoning count omits the category", %{conn: conn} do
    key = "console-unmetered-reasoning-operator"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)

    streamer = fn _request, callback, _options ->
      callback.({:reasoning_delta, "Weighing the fleet."})
      callback.({:text_delta, "The fleet is idle."})

      {:ok,
       %{
         "object" => "response",
         "model" => "stealth/ox-alpha",
         "assistant_content" => "The fleet is idle.",
         "reasoning_summary" => "Weighing the fleet.",
         "usage" => %{
           "input_tokens" => 24,
           "output_tokens" => 8,
           "total_tokens" => 32,
           "output_tokens_details" => %{"reasoning_tokens" => 0}
         }
       }}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Report the fleet.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-usage-#{run_id}", "Input 24")
    refute has_element?(view, "#chat-console-usage-#{run_id}", "Reasoning")
    assert has_element?(view, "#chat-console-token-input", "24")
    refute has_element?(view, "#chat-console-token-reasoning")
  end

  test "a completed turn shows a context meter where a window is configured", %{conn: conn} do
    key = "console-context-operator"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)
    Application.put_env(:openagents, :openrouter_context_window, 128_000)
    on_exit(fn -> Application.put_env(:openagents, :openrouter_context_window, nil) end)

    streamer = fn _request, _callback, _options ->
      {:ok,
       %{
         "assistant_content" => "Done.",
         "usage" => %{"total_tokens" => 640, "prompt_tokens" => 600, "completion_tokens" => 40}
       }}
    end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Measure the window.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-evidence-#{run_id}")
  end

  test "a rate-limited turn is retryable", %{conn: conn} do
    key = "console-retry-operator"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)

    streamer = fn _request, _callback, _options -> {:error, :rate_limited} end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Retry me.", subscriber: self(), streamer: streamer)

    assert_receive {:account_chat_completed, ^run_id, {:error, :rate_limited}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-error-#{run_id}", "rate-limited")
    assert has_element?(view, ~s(#chat-console-error-#{run_id}[role="alert"]))

    assert has_element?(
             view,
             ~s(#chat-console-retry-#{run_id}[phx-value-prompt="Retry me."])
           )
  end

  test "a malformed provider stream is retryable", %{conn: conn} do
    key = "console-malformed-operator"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)

    streamer = fn _request, _callback, _options -> {:error, :invalid_response} end

    assert {:ok, %{"id" => run_id}} =
             AccountTurns.submit(user, "Send a broken event.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:error, :invalid_response}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-console-error-#{run_id}")
    assert has_element?(view, "#chat-console-retry-#{run_id}")
  end

  test "the composer shows a safe inline error when OpenRouter is not configured", %{conn: conn} do
    conn = log_in_admin_user(conn, "console-composer-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#chat-console-form", %{"chat" => %{"message" => "Draft the release notes."}})
    |> render_submit()

    assert has_element?(
             view,
             ~s([data-message-role="user"]),
             "Draft the release notes."
           )

    assert has_element?(view, ~s([role="alert"]), "OpenRouter is not configured")
    assert has_element?(view, ~s(#chat_message), "Draft the release notes.")
  end

  test "a non-operator on a live socket is still turned away by the mount hook", %{conn: conn} do
    # The plug gate runs on the initial document request; this drives the
    # LiveView mount directly so the on_mount hook is what answers.
    conn = log_in_chatting_user(conn, "socket-not-an-operator")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat")
  end

  test "reasoning stays interleaved with successive tool attempts" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:stream_id, 42)
      |> Phoenix.Component.assign(:streaming?, true)
      |> Phoenix.Component.assign(:assistant_reasoning, nil)
      |> Phoenix.Component.assign(:assistant_tool_calls, [])
      |> Phoenix.Component.assign(:assistant_blocks, [])

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42, {:reasoning_delta, "First attempt."}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_started,
          %{
            "call_id" => "call-1",
            "name" => "read_repository_file",
            "arguments" => ~s({"path":"null"})
          }}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_failed, %{"call_id" => "call-1", "error" => "Not found"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42, {:reasoning_delta, "Second attempt."}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_started,
          %{
            "call_id" => "call-2",
            "name" => "read_repository_file",
            "arguments" => ~s({"path":"README.md"})
          }}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_failed, %{"call_id" => "call-2", "error" => "Still not found"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 42, {:reasoning_delta, "Report the failure."}},
        socket
      )

    assert [first_reasoning, first_tool, second_reasoning, second_tool, final_reasoning] =
             socket.assigns.assistant_blocks

    assert first_reasoning.type == :reasoning
    assert first_reasoning.text == "First attempt."
    assert is_integer(first_reasoning.duration)
    assert first_tool.type == :tool
    assert first_tool.tool_call.state == "output-error"
    assert first_tool.tool_call.error == "Not found"
    assert second_reasoning.type == :reasoning
    assert second_reasoning.text == "Second attempt."
    assert is_integer(second_reasoning.duration)
    assert second_tool.type == :tool
    assert second_tool.tool_call.state == "output-error"
    assert second_tool.tool_call.error == "Still not found"
    assert final_reasoning.type == :reasoning
    assert final_reasoning.text == "Report the failure."
    assert is_nil(final_reasoning.duration)
  end

  test "the browser renders durable tool workspace, duration, output, and receipts", %{conn: conn} do
    key = "placeholder-tool-metadata"
    user = github_user(key)
    conn = log_in_admin_user(conn, key)

    streamer = fn _request, callback, _options ->
      callback.(
        {:tool_call_started,
         %{
           "call_id" => "call-read",
           "name" => "read",
           "arguments" => ~s({"path":"README.md"})
         }}
      )

      callback.(
        {:tool_call_completed,
         %{
           "call_id" => "call-read",
           "output" => %{
             "schema" => "sarah.tool_outcome.v1",
             "status" => "succeeded",
             "result" => %{"content" => "OpenAgents"},
             "workspace" => %{
               "type" => "forge_worktree",
               "path" => "/private/var/lib/openagents/workspaces/repo"
             },
             "target_receipt_refs" => ["receipt:read:1"],
             "started_at" => "2026-08-22T19:43:28.000Z",
             "completed_at" => "2026-08-22T19:43:28.025Z"
           }
         }}
      )

      {:ok, %{"assistant_content" => "Read the file."}}
    end

    assert {:ok, %{"id" => run_id}} =
             OpenAgents.Chat.AccountTurns.submit(user, "Read the README.",
               subscriber: self(),
               streamer: streamer
             )

    assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    {:ok, view, _html} = live(conn, ~p"/chat")

    block_id = "chat-console-block-#{run_id}-0"
    assert has_element?(view, "##{block_id}-metadata", "succeeded")
    assert has_element?(view, "##{block_id}-metadata", "repo")
    refute render(view) =~ "/private/var/lib/openagents"
    assert has_element?(view, "##{block_id}-metadata", "25 ms")
    assert has_element?(view, "##{block_id}-output", "OpenAgents")
    assert has_element?(view, "##{block_id}-receipts", "receipt:read:1")
  end

  test "streaming typed tool failures retain status and error code" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:stream_id, 84)
      |> Phoenix.Component.assign(:streaming?, true)
      |> Phoenix.Component.assign(:assistant_tool_calls, [])
      |> Phoenix.Component.assign(:assistant_blocks, [])

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 84,
         {:tool_call_started, %{"call_id" => "call-edit", "name" => "edit", "arguments" => "{}"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatConsoleLive.handle_info(
        {:openrouter_stream_event, 84,
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
              "workspace" => %{"path" => "/private/var/lib/openagents/workspaces/repo"}
            }
          }}},
        socket
      )

    assert [%{tool_call: tool}] = socket.assigns.assistant_blocks
    assert tool.status == "failed"
    assert tool.state == "output-error"
    assert tool.error_code == "workspace_read_only"
    assert tool.error == "The workspace is read-only."
    assert tool.workspace_label == "repo"
  end
end
