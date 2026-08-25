defmodule OpenAgentsWeb.ResponsesController do
  @moduledoc """
  The OpenResponses surface, opening as a stub.

  `POST /api/v1/responses` takes an OpenResponses request — `input` as a
  string or a list of items — and answers with one completed assistant
  message reading `Acknowledged.` No model is consulted and nothing is
  recorded. The route exists so the coder's turn loop can move onto the
  OpenResponses shape before a provider stands behind it.

  Both of the specification's answer shapes are served. Without `stream`,
  the non-streaming response object. With `"stream": true`, server-sent
  events carrying the semantic sequence — `response.created`,
  `response.output_item.added`, `response.content_part.added`,
  `response.output_text.delta`, the matching `done` events, and
  `response.completed` — each numbered by `sequence_number`, so a client
  built against this stub is built against the real event grammar. The text
  arrives in more than one delta on purpose: a client that concatenates
  deltas is proven here, not on the first provider.

  This codebase already speaks OpenResponses as a client
  (`OpenAgents.Providers.OpenAI` at `/v1/responses` upstream); this is the
  first time it answers as one.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgentsWeb.ApiError

  @answer "Acknowledged."

  @doc "Answers any OpenResponses request with one acknowledged message."
  def create(conn, params) do
    case params["input"] do
      input when is_binary(input) and input != "" -> respond(conn, params)
      [_ | _] -> respond(conn, params)
      _missing -> ApiError.validation_failed(conn, %{"input" => ["is required"]})
    end
  end

  defp respond(conn, params) do
    response = response_object(params)

    if params["stream"] == true do
      stream(conn, response)
    else
      json(conn, response)
    end
  end

  # The whole semantic sequence for one message, numbered and in order. Built
  # complete rather than emitted from a loop: the stub's answer is known, and
  # a list the whole of which is visible here is a list a reader can check
  # against the specification event by event.
  defp stream(conn, response) do
    [message] = response["output"]
    part = %{"type" => "output_text", "text" => "", "annotations" => []}
    added = %{message | "status" => "in_progress", "content" => []}
    base = %{"item_id" => message["id"], "output_index" => 0, "content_index" => 0}

    events =
      [
        {"response.created", %{"response" => %{response | "status" => "in_progress"}}},
        {"response.output_item.added", %{"output_index" => 0, "item" => added}},
        {"response.content_part.added", Map.put(base, "part", part)},
        {"response.output_text.delta", Map.put(base, "delta", "Acknow")},
        {"response.output_text.delta", Map.put(base, "delta", "ledged.")},
        {"response.output_text.done", Map.put(base, "text", @answer)},
        {"response.content_part.done", Map.put(base, "part", %{part | "text" => @answer})},
        {"response.output_item.done", %{"output_index" => 0, "item" => message}},
        {"response.completed", %{"response" => response}}
      ]
      |> Enum.with_index()
      |> Enum.map(fn {{type, payload}, sequence} ->
        data =
          payload
          |> Map.put("type", type)
          |> Map.put("sequence_number", sequence)
          |> Jason.encode!()

        "event: #{type}\ndata: #{data}\n\n"
      end)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    Enum.reduce_while(events, conn, fn frame, conn ->
      case chunk(conn, frame) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp response_object(params) do
    %{
      "id" => "resp_" <> identifier(),
      "object" => "response",
      "created_at" => System.os_time(:second),
      "status" => "completed",
      "model" => model_of(params),
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_" <> identifier(),
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => @answer, "annotations" => []}
          ]
        }
      ],
      "error" => nil,
      "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    }
  end

  # Echoed when the caller named one, and the product name when not: no vendor
  # default leaks out of a route no vendor stands behind.
  defp model_of(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp model_of(_params), do: "openagents-coder"

  defp identifier, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
