defmodule OpenAgents.Chat.GeminiTest do
  @moduledoc """
  The Gemini adapter's half of the backend contract.

  Gemini rejects the vocabulary the other backends use: there is no
  `assistant` role, a system message is a separate field rather than a message,
  and the model is a path segment rather than a body key. Each of those is a
  request the API refuses outright, so each is pinned here.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.Gemini

  setup {Req.Test, :verify_on_exit!}

  defp frame(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"

  defp text_chunk(text, extra \\ %{}) do
    Map.merge(
      %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}], "role" => "model"}}]},
      extra
    )
  end

  defp terminal(extra \\ %{}) do
    Map.merge(
      %{"candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "STOP"}]},
      extra
    )
  end

  defp respond(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp stream(request, opts \\ []) do
    parent = self()

    result =
      Gemini.stream(
        request,
        fn event -> send(parent, {:event, event}) end,
        Keyword.merge(
          [api_key: "test-key", request_options: [plug: {Req.Test, __MODULE__}]],
          opts
        )
      )

    {result, drain()}
  end

  defp drain(acc \\ []) do
    receive do
      {:event, event} -> drain(acc ++ [event])
    after
      0 -> acc
    end
  end

  describe "request translation" do
    test "maps roles to Gemini's vocabulary and hoists the system message" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["contents"] == [
                 %{"role" => "user", "parts" => [%{"text" => "Hello."}]},
                 %{"role" => "model", "parts" => [%{"text" => "Hi."}]},
                 %{"role" => "user", "parts" => [%{"text" => "More."}]}
               ]

        assert body["systemInstruction"] == %{"parts" => [%{"text" => "Be terse."}]}

        # The model is a path segment. A `model` body key is not how Gemini is
        # addressed, and sending one would silently do nothing.
        refute Map.has_key?(body, "model")
        assert conn.request_path =~ "gemini-3.7-flash:streamGenerateContent"
        assert conn.query_string == "alt=sse"

        respond(frame(text_chunk("ok")) <> frame(terminal())).(conn)
      end)

      {{:ok, _completion}, _events} =
        stream(%{
          "model" => "gemini-3.7-flash",
          "reasoning" => "high",
          "messages" => [
            %{"role" => "system", "content" => "Be terse."},
            %{"role" => "user", "content" => "Hello."},
            %{"role" => "assistant", "content" => "Hi."},
            %{"role" => "user", "content" => "More."}
          ]
        })
    end

    test "asks for reasoning text, not only a reasoning count" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        config = Jason.decode!(raw)["generationConfig"]

        assert config["thinkingConfig"]["includeThoughts"] == true
        assert config["thinkingConfig"]["thinkingLevel"] == "high"
        assert is_integer(config["maxOutputTokens"])

        respond(frame(text_chunk("ok")) <> frame(terminal())).(conn)
      end)

      {{:ok, _completion}, _events} =
        stream(%{
          "model" => "gemini-3.7-flash",
          "reasoning" => "high",
          "messages" => [%{"role" => "user", "content" => "Hi."}]
        })
    end

    test "the two efforts below low ask for the lowest level this model accepts" do
      # `minimal` is a documented level `gemini-3.7-flash` refuses outright.
      for effort <- ["none", "minimal"] do
        assert {:ok, payload} =
                 Gemini.payload(%{
                   "reasoning" => effort,
                   "messages" => [%{"role" => "user", "content" => "Hi."}]
                 })

        assert payload["generationConfig"]["thinkingConfig"]["thinkingLevel"] == "low"
      end
    end

    test "a conversation with nothing to say is not a request" do
      assert {:error, :invalid_response} =
               Gemini.payload(%{"messages" => [%{"role" => "system", "content" => "Be terse."}]})
    end
  end

  describe "streaming" do
    test "emits reasoning and text as the same events every backend emits" do
      body =
        frame(%{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "Thinking.", "thought" => true}]}}
          ]
        }) <>
          frame(text_chunk("The answer.")) <>
          frame(
            terminal(%{
              "usageMetadata" => %{
                "promptTokenCount" => 17,
                "candidatesTokenCount" => 14,
                "totalTokenCount" => 304,
                "thoughtsTokenCount" => 273
              }
            })
          )

      Req.Test.expect(__MODULE__, respond(body))

      {{:ok, completion}, events} =
        stream(%{
          "model" => "gemini-3.7-flash",
          "reasoning" => "high",
          "messages" => [%{"role" => "user", "content" => "Hi."}]
        })

      assert events == [{:reasoning_delta, "Thinking."}, {:text_delta, "The answer."}]
      assert completion["assistant_content"] == "The answer."
      assert completion["reasoning_summary"] == "Thinking."
      assert completion["usage"]["output_tokens_details"] == %{"reasoning_tokens" => 273}
    end

    test "the completion feeds the turn's stored counts without a Gemini branch" do
      body =
        frame(text_chunk("hi")) <>
          frame(
            terminal(%{
              "usageMetadata" => %{
                "promptTokenCount" => 17,
                "candidatesTokenCount" => 14,
                "totalTokenCount" => 304,
                "thoughtsTokenCount" => 273
              }
            })
          )

      Req.Test.expect(__MODULE__, respond(body))

      {{:ok, completion}, _events} =
        stream(%{
          "model" => "gemini-3.7-flash",
          "messages" => [%{"role" => "user", "content" => "x"}]
        })

      # These are the exact keys `AccountTurns.usage_counts/1` reads, so a
      # Gemini turn stores its counts through the reader every backend uses.
      assert completion["usage"]["input_tokens"] == 17
      assert completion["usage"]["output_tokens"] == 14
      assert completion["usage"]["total_tokens"] == 304
    end
  end

  describe "failure" do
    test "a rate limit is retryable, an argument error is not" do
      for {status, expected} <- [
            {429, :rate_limited},
            {503, :service_unavailable},
            {400, :provider_unavailable}
          ] do
        Req.Test.expect(__MODULE__, fn conn ->
          Plug.Conn.send_resp(conn, status, ~s({"error":{"code":#{status},"message":"no"}}))
        end)

        assert {{:error, ^expected}, []} =
                 stream(%{
                   "model" => "gemini-3.7-flash",
                   "messages" => [%{"role" => "user", "content" => "Hi."}]
                 })
      end
    end

    test "a stream that stops before its finishReason is truncated" do
      Req.Test.expect(__MODULE__, respond(frame(text_chunk("half an answ"))))

      assert {{:error, :stream_interrupted}, [{:text_delta, "half an answ"}]} =
               stream(%{
                 "model" => "gemini-3.7-flash",
                 "messages" => [%{"role" => "user", "content" => "Hi."}]
               })
    end

    test "a transport failure does not escape as an exception" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {{:error, :provider_unavailable}, []} =
               stream(%{
                 "model" => "gemini-3.7-flash",
                 "messages" => [%{"role" => "user", "content" => "Hi."}]
               })
    end

    test "an unconfigured deployment says so rather than calling out with no key" do
      assert {:error, :missing_api_key} =
               Gemini.stream(
                 %{
                   "model" => "gemini-3.7-flash",
                   "messages" => [%{"role" => "user", "content" => "Hi."}]
                 },
                 fn _event -> :ok end,
                 api_key: ""
               )
    end
  end
end
