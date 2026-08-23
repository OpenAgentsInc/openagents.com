defmodule OpenAgents.Chat.OpenRouterTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionContext, ExecutionResult, Registry, Tool}

  defmodule RepositoryFileToolStub do
    @moduledoc false
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification do
      %Tool{
        module_id: "sarah.tool.openrouter_repository_file_test",
        name: "read_repository_file",
        version: 1,
        description: "Reads a file from a connected repository for an OpenRouter adapter test.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repository" => %{"type" => "string"},
            "path" => %{"type" => "string"},
            "ref" => %{"type" => "string"}
          },
          "required" => ["repository", "path", "ref"],
          "additionalProperties" => false
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "repository" => %{"type" => "string"},
            "ref" => %{"type" => "string"},
            "path" => %{"type" => "string"},
            "content" => %{"type" => "string"},
            "size_bytes" => %{"type" => "integer"},
            "truncated" => %{"type" => "boolean"}
          },
          "required" => [
            "repository",
            "ref",
            "path",
            "content",
            "size_bytes",
            "truncated"
          ],
          "additionalProperties" => false
        },
        side_effect: :read_only,
        required_scope: "browser_conversation",
        required_authority: "repository.read",
        executor: %{id: "sarah.local", disclosure: "OpenRouter adapter test executor"},
        maintainer: "OpenAgents",
        attribution: ["OpenAgentsInc/openagents.com"],
        policy_facets: %{"privacy" => "browser_scoped", "residency" => "host"},
        module_metadata:
          Metadata.first_party("repository.read", "browser_conversation",
            effect: :read_only,
            privacy: "browser_scoped",
            residency: "host"
          ),
        timeout_ms: 100,
        maximum_input_bytes: 1_024,
        maximum_output_bytes: 2_048,
        implementation: __MODULE__
      }
    end

    @impl true
    def execute(
          %{"repository" => "OpenAgentsInc/openagents.com", "path" => "README.md"},
          %ExecutionContext{owner_user_id: "user-test"}
        ) do
      {:ok,
       %ExecutionResult{
         result: %{
           "repository" => "OpenAgentsInc/openagents.com",
           "ref" => "main",
           "path" => "README.md",
           "content" => "# OpenAgents\n",
           "size_bytes" => 13,
           "truncated" => false
         }
       }}
    end
  end

  defmodule RepositorySequenceReadToolStub do
    @moduledoc false
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification,
      do:
        OpenAgents.Chat.OpenRouterTest.sequence_tool_spec(
          "read",
          __MODULE__,
          "Reads a file from the test repository workspace."
        )

    @impl true
    def execute(%{"path" => path}, %ExecutionContext{owner_user_id: agent}) when is_pid(agent) do
      content = Agent.get(agent, & &1)
      {:ok, %ExecutionResult{result: %{"path" => path, "content" => content}}}
    end
  end

  defmodule RepositorySequenceWriteToolStub do
    @moduledoc false
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification,
      do:
        OpenAgents.Chat.OpenRouterTest.sequence_tool_spec(
          "write",
          __MODULE__,
          "Writes a complete file to the test repository workspace."
        )

    @impl true
    def execute(%{"path" => path, "content" => content}, %ExecutionContext{
          owner_user_id: agent
        })
        when is_pid(agent) do
      :ok = Agent.update(agent, fn _current -> content end)
      {:ok, %ExecutionResult{result: %{"path" => path, "content" => content}}}
    end
  end

  defmodule RepositorySequenceEditToolStub do
    @moduledoc false
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification,
      do:
        OpenAgents.Chat.OpenRouterTest.sequence_tool_spec(
          "edit",
          __MODULE__,
          "Edits an exact string in the test repository workspace."
        )

    @impl true
    def execute(
          %{"path" => path, "old_string" => old_string, "new_string" => new_string},
          %ExecutionContext{owner_user_id: agent}
        )
        when is_pid(agent) do
      case Agent.get_and_update(agent, fn content ->
             if String.contains?(content, old_string) do
               updated = String.replace(content, old_string, new_string)
               {{:ok, updated}, updated}
             else
               {{:error, :no_match}, content}
             end
           end) do
        {:ok, content} ->
          {:ok, %ExecutionResult{result: %{"path" => path, "content" => content}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def sequence_tool_spec(name, implementation, description) do
    {properties, required} =
      case name do
        "read" ->
          {%{
             "path" => %{"type" => "string"},
             "from" => %{"type" => "string"}
           }, ["path"]}

        "write" ->
          {%{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}},
           ["path", "content"]}

        "edit" ->
          {%{
             "path" => %{"type" => "string"},
             "old_string" => %{"type" => "string"},
             "new_string" => %{"type" => "string"}
           }, ["path", "old_string", "new_string"]}
      end

    %Tool{
      module_id: "sarah.tool.openrouter_#{name}_sequence_test",
      name: name,
      version: 1,
      description: description,
      input_schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => true
      },
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{id: "sarah.local", disclosure: "OpenRouter sequence test executor"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_scoped", "residency" => "host"},
      module_metadata:
        Metadata.first_party("repository.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_scoped",
          residency: "host"
        ),
      timeout_ms: 100,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 2_048,
      implementation: implementation
    }
  end

  defp tool_execution_context do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:openrouter-test",
      authorities: MapSet.new(["repository.read"]),
      surface: "text",
      conversation_id: "openrouter-test",
      owner_user_id: "user-test",
      owner_visitor_id: "visitor-test"
    }
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
            "type" => "response.completed",
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
          "type" => "response.completed",
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

  test "accepts legacy response.done when the terminal response contains only metadata" do
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
            "type" => "response.completed",
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

      assert Enum.map(conn.body_params["tools"], & &1["name"]) == ["read_repository_file"]

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

      [user_input | provider_and_tool_output] = conn.body_params["input"]

      assert user_input == %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Summarize the README."}]
             }

      assert Enum.take(provider_and_tool_output, 3) == expected_tool_provider_output()

      assert %{
               "type" => "function_call_output",
               "call_id" => "call_demo",
               "output" => tool_output
             } = List.last(provider_and_tool_output)

      assert provider_and_tool_output ==
               expected_tool_provider_output() ++
                 [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_demo",
                     "output" => tool_output
                   }
                 ]

      assert %{
               "schema" => "sarah.tool_outcome.v1",
               "status" => "succeeded",
               "result" => %{
                 "repository" => "OpenAgentsInc/openagents.com",
                 "path" => "README.md",
                 "content" => "# OpenAgents\n"
               }
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
    assert {:ok, tool_registry_snapshot} = Registry.build([RepositoryFileToolStub])

    assert {:ok, %{"assistant_content" => "OpenAgents is an agent platform."}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [%{"role" => "user", "content" => "Summarize the README."}]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               tool_registry_snapshot: tool_registry_snapshot,
               tool_execution_context: tool_execution_context(),
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event, {:text_delta, "OpenAgents is an agent platform."}}

    assert_receive {:openrouter_event,
                    {:tool_call_started,
                     %{
                       "call_id" => "call_demo",
                       "name" => "read_repository_file",
                       "arguments" =>
                         "{\"repository\":\"OpenAgentsInc/openagents.com\",\"path\":\"README.md\",\"ref\":\"\"}"
                     }}}

    assert_receive {:openrouter_event,
                    {:tool_call_completed, %{"call_id" => "call_demo", "output" => tool_output}}}

    assert %{
             "schema" => "sarah.tool_outcome.v1",
             "status" => "succeeded",
             "result" => %{
               "repository" => "OpenAgentsInc/openagents.com",
               "path" => "README.md",
               "content" => "# OpenAgents\n"
             }
           } = Jason.decode!(tool_output)
  end

  test "replays provider output around ordered read, write, edit, and reread calls" do
    repository_state = start_supervised!({Agent, fn -> "initial" end})

    fixtures =
      Enum.map(
        ["repo_read", "repo_write", "repo_edit", "repo_reread"],
        &repository_sequence_fixture/1
      )

    Enum.with_index(fixtures)
    |> Enum.each(fn {fixture, index} ->
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/api/v1/responses"

        assert_repository_sequence_history(
          conn.body_params["input"],
          Enum.take(fixtures, index)
        )

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, fixture.raw)
      end)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert_repository_sequence_history(conn.body_params["input"], fixtures)

      body =
        sse(%{
          "type" => "response.output_text.delta",
          "delta" => "The file now contains alpha gamma."
        }) <>
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_repo_final",
              "object" => "response",
              "status" => "completed",
              "model" => "stealth/ox-alpha",
              "output" => [
                %{
                  "type" => "message",
                  "id" => "msg_repo_final",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => "The file now contains alpha gamma.",
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

    assert {:ok, tool_registry_snapshot} =
             Registry.build([
               RepositorySequenceReadToolStub,
               RepositorySequenceWriteToolStub,
               RepositorySequenceEditToolStub
             ])

    execution_context = %{
      tool_execution_context()
      | owner_user_id: repository_state
    }

    assert {:ok, %{"assistant_content" => "The file now contains alpha gamma."}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => "Read notes.txt, rewrite it, edit it, and read it again."
                   }
                 ]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               tool_registry_snapshot: tool_registry_snapshot,
               tool_execution_context: execution_context,
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert Agent.get(repository_state, & &1) == "alpha gamma"

    assert_repository_sequence_events([
      {"call_repo_read", "read", "initial"},
      {"call_repo_write", "write", "alpha beta"},
      {"call_repo_edit", "edit", "alpha gamma"},
      {"call_repo_reread", "read", "alpha gamma"}
    ])
  end

  defp assert_repository_sequence_history([user_input | history], prior_fixtures) do
    assert user_input == %{
             "type" => "message",
             "role" => "user",
             "content" => [
               %{
                 "type" => "input_text",
                 "text" => "Read notes.txt, rewrite it, edit it, and read it again."
               }
             ]
           }

    remaining =
      Enum.reduce(prior_fixtures, history, fn fixture, remaining ->
        {provider_output, remaining} = Enum.split(remaining, length(fixture.output))
        assert provider_output == fixture.output

        assert [
                 %{
                   "type" => "function_call_output",
                   "call_id" => call_id,
                   "output" => encoded_outcome
                 }
                 | remaining
               ] = remaining

        assert call_id == fixture.call_id
        assert %{"schema" => "sarah.tool_outcome.v1"} = Jason.decode!(encoded_outcome)
        remaining
      end)

    assert remaining == []
  end

  defp assert_repository_sequence_events(expected) do
    Enum.each(expected, fn {call_id, name, expected_content} ->
      assert_receive {:openrouter_event,
                      {:tool_call_started, %{"call_id" => ^call_id, "name" => ^name}}}

      assert_receive {:openrouter_event,
                      {:tool_call_completed,
                       %{"call_id" => ^call_id, "output" => encoded_outcome}}}

      assert %{
               "status" => "succeeded",
               "result" => %{"content" => ^expected_content}
             } = Jason.decode!(encoded_outcome)
    end)
  end

  defp repository_sequence_fixture(name) do
    raw =
      Path.expand("../../fixtures/openrouter/responses_#{name}_call.sse", __DIR__)
      |> File.read!()

    response =
      raw
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
      |> Enum.reject(&(&1 == "[DONE]"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find_value(fn
        %{"type" => "response.completed", "response" => response} -> response
        _event -> nil
      end)

    function_call = Enum.find(response["output"], &(&1["type"] == "function_call"))

    %{raw: raw, output: response["output"], call_id: function_call["call_id"]}
  end

  defp expected_tool_provider_output do
    [
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
        "type" => "message",
        "id" => "msg_tool_preamble",
        "role" => "assistant",
        "status" => "completed",
        "content" => [
          %{
            "type" => "output_text",
            "text" => "I will inspect the connected repository.",
            "annotations" => []
          }
        ]
      },
      %{
        "type" => "function_call",
        "id" => "fc_demo",
        "call_id" => "call_demo",
        "name" => "read_repository_file",
        "arguments" =>
          "{\"repository\":\"OpenAgentsInc/openagents.com\",\"path\":\"README.md\",\"ref\":\"\"}",
        "status" => "completed"
      }
    ]
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"
end
