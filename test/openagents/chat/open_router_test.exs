defmodule OpenAgents.Chat.OpenRouterTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter

  defmodule RepositoryFileStub do
    @moduledoc false

    def definitions, do: OpenAgents.Chat.Tools.RepositoryFile.definitions()

    def execute("read_repository_file", arguments, %{user_id: "user-test"}) do
      assert_arguments = Jason.decode!(arguments)
      "OpenAgentsInc/openagents.com" = assert_arguments["repository"]
      "README.md" = assert_arguments["path"]

      {:ok,
       %{
         "repository" => "OpenAgentsInc/openagents.com",
         "ref" => "main",
         "path" => "README.md",
         "content" => "# OpenAgents\n",
         "size_bytes" => 13,
         "truncated" => false
       }}
    end
  end

  setup {Req.Test, :verify_on_exit!}

  test "sends an OpenRouter-compatible Ox Alpha request with a free fallback" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/chat/completions"
      assert ["Bearer test-openrouter-key"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["OpenAgents"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

      assert ["cloud-agent,general-chat"] =
               Plug.Conn.get_req_header(conn, "x-openrouter-categories")

      assert [referer] = Plug.Conn.get_req_header(conn, "http-referer")
      assert String.starts_with?(referer, "http")

      assert %{
               "model" => "stealth/ox-alpha",
               "messages" => [%{"role" => "user", "content" => "Hello"}]
             } = conn.body_params

      assert conn.body_params["models"] == ["openrouter/free"]

      Req.Test.json(conn, %{
        "id" => "gen-test",
        "object" => "chat.completion",
        "model" => "meta-llama/example:free",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Hello from a free model."},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 5, "total_tokens" => 6}
      })
    end)

    assert {:ok, completion} =
             OpenRouter.complete(
               %{
                 "model" => "stealth/ox-alpha",
                 "models" => ["openrouter/free"],
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               },
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert completion["choices"] |> hd() |> get_in(["message", "content"]) ==
             "Hello from a free model."
  end

  test "normalizes a free-model rate limit" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "rate limited") end)

    assert {:error, :rate_limited} =
             OpenRouter.complete(
               %{
                 "model" => "stealth/ox-alpha",
                 "models" => ["openrouter/free"],
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               },
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "prefers the Responses API and streams structured history" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"
      assert conn.body_params["stream"] == true
      assert ["OpenAgents"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

      assert ["cloud-agent,general-chat"] =
               Plug.Conn.get_req_header(conn, "x-openrouter-categories")

      assert %{
               "model" => "stealth/ox-alpha",
               "reasoning" => %{
                 "effort" => "max",
                 "exclude" => false,
                 "summary" => "detailed"
               },
               "include" => ["reasoning.encrypted_content"],
               "max_output_tokens" => 9_000,
               "models" => ["openrouter/free"],
               "input" => [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "Hello"}]
                 },
                 %{
                   "type" => "message",
                   "role" => "assistant",
                   "id" => "msg_previous",
                   "status" => "completed",
                   "content" => [%{"type" => "output_text", "text" => "Hi", "annotations" => []}]
                 },
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "Continue"}]
                 }
               ]
             } = conn.body_params

      body =
        sse(%{
          "type" => "response.reasoning.delta",
          "delta" => "Checking the prior context."
        }) <>
          sse(%{
            "type" => "response.content_part.delta",
            "delta" => "Hello"
          }) <>
          sse(%{
            "type" => "response.content_part.delta",
            "delta" => " world"
          }) <>
          sse(%{
            "type" => "response.done",
            "response" => %{
              "id" => "resp_test",
              "object" => "response",
              "model" => "stealth/ox-alpha",
              "output" => [
                %{
                  "type" => "reasoning",
                  "id" => "rs_test",
                  "encrypted_content" => "encrypted-reasoning",
                  "summary" => [
                    %{"type" => "summary_text", "text" => "Checked the prior context."}
                  ]
                },
                %{
                  "type" => "message",
                  "id" => "msg_test",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [
                    %{"type" => "output_text", "text" => "Hello world", "annotations" => []}
                  ]
                }
              ]
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()

    assert {:ok,
            %{
              "object" => "response",
              "model" => "stealth/ox-alpha",
              "assistant_message_id" => "msg_test",
              "assistant_content" => "Hello world",
              "reasoning_summary" => "Checked the prior context.",
              "reasoning_items" => [
                %{
                  "type" => "reasoning",
                  "id" => "rs_test",
                  "encrypted_content" => "encrypted-reasoning",
                  "summary" => [
                    %{"type" => "summary_text", "text" => "Checked the prior context."}
                  ]
                }
              ]
            }} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "models" => ["openrouter/free"],
                 "reasoning" => "max",
                 "messages" => [
                   %{"role" => "user", "content" => "Hello"},
                   %{
                     "role" => "assistant",
                     "content" => "Hi",
                     "id" => "msg_previous",
                     "status" => "completed"
                   },
                   %{"role" => "user", "content" => "Continue"}
                 ]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event, {:text_delta, "Hello"}}
    assert_receive {:openrouter_event, {:text_delta, " world"}}
    assert_receive {:openrouter_event, {:reasoning_delta, "Checking the prior context."}}
  end

  test "replays encrypted reasoning blocks in Responses conversation history" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "reasoning",
                 "id" => "rs_previous",
                 "encrypted_content" => "encrypted-previous"
               },
               %{"type" => "message", "role" => "assistant", "id" => "msg_previous"},
               %{"type" => "message", "role" => "user"}
             ] = conn.body_params["input"]

      body =
        sse(%{
          "type" => "response.done",
          "response" => %{
            "object" => "response",
            "model" => "stealth/ox-alpha",
            "output" => [
              %{
                "type" => "message",
                "id" => "msg_next",
                "role" => "assistant",
                "status" => "completed",
                "content" => [%{"type" => "output_text", "text" => "Continued"}]
              }
            ]
          }
        }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok, %{"assistant_content" => "Continued"}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [
                   %{"role" => "user", "content" => "Think"},
                   %{
                     "role" => "assistant",
                     "content" => "Prior answer",
                     "id" => "msg_previous",
                     "status" => "completed",
                     "reasoning_items" => [
                       %{
                         "type" => "reasoning",
                         "id" => "rs_previous",
                         "encrypted_content" => "encrypted-previous"
                       }
                     ]
                   },
                   %{"role" => "user", "content" => "Continue"}
                 ]
               },
               fn _event -> :ok end,
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "falls back to Chat Completions when the Responses API is unavailable" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/chat/completions"
      assert conn.body_params["stream"] == true

      assert conn.body_params["messages"] == [
               %{"role" => "user", "content" => "Hello"},
               %{"role" => "assistant", "content" => "Hi"},
               %{"role" => "user", "content" => "Continue"}
             ]

      body =
        sse(%{
          "id" => "gen-stream",
          "object" => "chat.completion.chunk",
          "model" => "stealth/ox-alpha",
          "choices" => [%{"index" => 0, "delta" => %{"content" => "Fallback"}}]
        }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()

    assert {:ok, %{"object" => "chat.completion", "model" => "stealth/ox-alpha"}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [
                   %{"role" => "user", "content" => "Hello"},
                   %{
                     "role" => "assistant",
                     "content" => "Hi",
                     "id" => "msg_previous",
                     "status" => "completed"
                   },
                   %{"role" => "user", "content" => "Continue"}
                 ]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event, {:text_delta, "Fallback"}}
  end

  test "preserves a structured Responses API validation error" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "invalid_prompt",
          "message" => "The selected model does not support this tool definition."
        },
        "error_type" => "unsupported_parameters"
      })
    end)

    assert {:error,
            {:provider_error, "unsupported_parameters",
             "The selected model does not support this tool definition."}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               },
               fn _event -> :ok end,
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "completes a streamed response when response.done contains only metadata" do
    Req.Test.expect(__MODULE__, fn conn ->
      body =
        sse(%{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "message",
            "id" => "msg_streamed",
            "role" => "assistant",
            "status" => "in_progress",
            "content" => []
          }
        }) <>
          sse(%{"type" => "response.content_part.delta", "delta" => "Streaming works."}) <>
          sse(%{
            "type" => "response.output_item.done",
            "item" => %{
              "type" => "message",
              "id" => "msg_streamed",
              "role" => "assistant",
              "status" => "completed",
              "content" => [
                %{"type" => "output_text", "text" => "Streaming works.", "annotations" => []}
              ]
            }
          }) <>
          sse(%{
            "type" => "response.done",
            "response" => %{
              "id" => "resp_streamed",
              "object" => "response",
              "status" => "completed"
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok,
            %{
              "object" => "response",
              "model" => "stealth/ox-alpha",
              "assistant_message_id" => "msg_streamed",
              "assistant_content" => "Streaming works."
            }} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               },
               fn _event -> :ok end,
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "streams canonical output and detailed reasoning deltas" do
    Req.Test.expect(__MODULE__, fn conn ->
      body =
        sse(%{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "message",
            "id" => "msg_canonical",
            "role" => "assistant",
            "status" => "in_progress",
            "content" => []
          }
        }) <>
          sse(%{
            "type" => "response.reasoning_summary_text.delta",
            "delta" => "Check the values."
          }) <>
          sse(%{"type" => "response.output_text.delta", "delta" => "Canonical"}) <>
          sse(%{"type" => "response.output_text.delta", "delta" => " stream"}) <>
          sse(%{
            "type" => "response.output_item.done",
            "item" => %{
              "type" => "message",
              "id" => "msg_canonical",
              "role" => "assistant",
              "status" => "completed",
              "content" => [
                %{"type" => "output_text", "text" => "Canonical stream", "annotations" => []}
              ]
            }
          }) <>
          sse(%{
            "type" => "response.done",
            "response" => %{
              "id" => "resp_canonical",
              "object" => "response",
              "status" => "completed"
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()

    assert {:ok,
            %{
              "assistant_content" => "Canonical stream",
              "reasoning_summary" => "Check the values."
            }} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event, {:reasoning_delta, "Check the values."}}
    assert_receive {:openrouter_event, {:text_delta, "Canonical"}}
    assert_receive {:openrouter_event, {:text_delta, " stream"}}
  end

  test "reads a repository file and continues the Responses conversation" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"

      assert Enum.map(conn.body_params["tools"], & &1["name"]) == [
               "read_repository_file",
               "list_repository_directory"
             ]

      assert conn.body_params["instructions"] =~
               "Never claim that a file or directory exists unless a tool result confirms it"

      assert Enum.all?(conn.body_params["tools"], fn tool ->
               tool["type"] == "function" and tool["strict"] == true and
                 tool["parameters"]["additionalProperties"] == false
             end)

      body =
        Path.expand("../../fixtures/openrouter/responses_tool_call.sse", __DIR__)
        |> File.read!()

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "reasoning",
                 "id" => "rs_demo",
                 "status" => "completed",
                 "summary" => [
                   %{
                     "type" => "summary_text",
                     "text" => "The user asked to read a repository file."
                   }
                 ],
                 "encrypted_content" => "encrypted-demo-reasoning"
               },
               %{
                 "type" => "function_call",
                 "id" => "fc_demo",
                 "call_id" => "call_demo",
                 "name" => "read_repository_file",
                 "arguments" =>
                   "{\"repository\":\"OpenAgentsInc/openagents.com\",\"path\":\"README.md\",\"ref\":null}",
                 "status" => "completed"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_demo",
                 "output" => tool_output
               }
             ] = conn.body_params["input"]

      assert %{
               "repository" => "OpenAgentsInc/openagents.com",
               "path" => "README.md",
               "content" => "# OpenAgents\n"
             } = Jason.decode!(tool_output)

      body =
        sse(%{
          "type" => "response.content_part.delta",
          "delta" => "OpenAgents is an agent platform."
        }) <>
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "object" => "response",
              "model" => "stealth/ox-alpha",
              "output" => [
                %{
                  "type" => "message",
                  "id" => "msg_after_tool",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => "OpenAgents is an agent platform.",
                      "annotations" => []
                    }
                  ]
                }
              ]
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()

    assert {:ok, %{"assistant_content" => "OpenAgents is an agent platform."}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [%{"role" => "user", "content" => "Summarize the README."}]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               tool_module: RepositoryFileStub,
               tool_context: %{user_id: "user-test"},
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event, {:text_delta, "OpenAgents is an agent platform."}}

    assert_receive {:openrouter_event,
                    {:tool_call_started,
                     %{
                       "call_id" => "call_demo",
                       "name" => "read_repository_file",
                       "arguments" =>
                         "{\"repository\":\"OpenAgentsInc/openagents.com\",\"path\":\"README.md\",\"ref\":null}"
                     }}}

    assert_receive {:openrouter_event,
                    {:tool_call_completed, %{"call_id" => "call_demo", "output" => tool_output}}}

    assert %{
             "repository" => "OpenAgentsInc/openagents.com",
             "path" => "README.md",
             "content" => "# OpenAgents\n"
           } = Jason.decode!(tool_output)
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"
end
