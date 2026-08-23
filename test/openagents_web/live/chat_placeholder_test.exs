defmodule OpenAgentsWeb.ChatPlaceholderTest do
  @moduledoc """
  `/chat` is the operator-only placeholder for the upcoming chat surface.

  The gate is worth its own file because it fails in two quiet directions: a
  missing plug lets a signed-in non-operator read the page, and a missing
  on_mount hook lets a LiveView event run on a socket that never passed the
  gate.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  test "an anonymous request is sent home", %{conn: conn} do
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "a signed-in non-operator is sent home", %{conn: conn} do
    conn = log_in_github_user(conn, "not-an-operator")
    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/"
  end

  test "an operator gets the placeholder", %{conn: conn} do
    conn = log_in_admin_user(conn, "placeholder-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-placeholder-transcript")
    assert has_element?(view, "#chat-placeholder-empty")
    assert has_element?(view, ~s(a[href="/sarah"]))
    assert has_element?(view, ~s(#chat-placeholder-form[data-submit-on-enter="true"]))
    assert has_element?(view, ~s(#chat-placeholder-form[data-clear-event="chat-preview:clear"]))
    assert has_element?(view, ~s(#chat_message[phx-mounted]))
    assert has_element?(view, ~s(#chat_reasoning[name="chat[reasoning]"]))
    assert has_element?(view, "#chat-placeholder-submit")
  end

  test "the composer shows a safe inline error when OpenRouter is not configured", %{conn: conn} do
    conn = log_in_admin_user(conn, "placeholder-composer-operator")
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("#chat-placeholder-form", %{"chat" => %{"message" => "Draft the release notes."}})
    |> render_submit()

    assert has_element?(
             view,
             ~s([data-message-role="user"]),
             "Draft the release notes."
           )

    assert has_element?(view, ~s([role="status"]), "OpenRouter is not configured")
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
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
        {:openrouter_stream_event, 42, {:reasoning_delta, "First attempt."}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
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
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_failed, %{"call_id" => "call-1", "error" => "Not found"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
        {:openrouter_stream_event, 42, {:reasoning_delta, "Second attempt."}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
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
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
        {:openrouter_stream_event, 42,
         {:tool_call_failed, %{"call_id" => "call-2", "error" => "Still not found"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
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

    block_id = "chat-placeholder-block-#{run_id}-0"
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
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
        {:openrouter_stream_event, 84,
         {:tool_call_started, %{"call_id" => "call-edit", "name" => "edit", "arguments" => "{}"}}},
        socket
      )

    {:noreply, socket} =
      OpenAgentsWeb.ChatPlaceholderLive.handle_info(
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
