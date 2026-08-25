defmodule OpenAgentsWeb.ResponsesControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  test "answers an anonymous caller while it is a stub", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/responses", %{input: "hello"})

    assert %{"status" => "completed"} = json_response(conn, 200)
  end

  test "acknowledges a string input in the OpenResponses shape", %{conn: conn} do
    conn =
      conn
      |> put_chat_api_token("responses-ack")
      |> post(~p"/api/v1/responses", %{input: "hello there"})

    assert %{
             "object" => "response",
             "status" => "completed",
             "model" => "openagents-coder",
             "output" => [message]
           } = json_response(conn, 200)

    assert %{
             "type" => "message",
             "role" => "assistant",
             "status" => "completed",
             "content" => [%{"type" => "output_text", "text" => "Acknowledged."}]
           } = message
  end

  test "acknowledges an item-list input and echoes the model", %{conn: conn} do
    conn =
      conn
      |> put_chat_api_token("responses-items")
      |> post(~p"/api/v1/responses", %{
        model: "anything",
        input: [%{role: "user", content: [%{type: "input_text", text: "hi"}]}]
      })

    assert %{"model" => "anything", "output" => [_]} = json_response(conn, 200)
  end

  test "refuses a request with no input, in the envelope", %{conn: conn} do
    conn =
      conn
      |> put_chat_api_token("responses-empty")
      |> post(~p"/api/v1/responses", %{})

    body = json_response(conn, 422)
    assert body["code"] == "validation_failed"
    assert body["errors"] == %{"input" => ["is required"]}
  end

  test "streams the semantic event sequence when asked to", %{conn: conn} do
    conn =
      conn
      |> put_chat_api_token("responses-stream")
      |> post(~p"/api/v1/responses", %{input: "hello", stream: true})

    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/event-stream"
    body = response(conn, 200)

    # The grammar, in order, each event numbered.
    for {event, at} <- Enum.with_index(~w(
          response.created
          response.output_item.added
          response.content_part.added
          response.output_text.delta
          response.output_text.delta
          response.output_text.done
          response.content_part.done
          response.output_item.done
          response.completed
        )) do
      assert body =~ "event: " <> event
      assert body =~ ~s("sequence_number":#{at})
    end

    # The text arrives in pieces a client must concatenate.
    assert body =~ ~s("delta":"Acknow")
    assert body =~ ~s("delta":"ledged.")
    refute body =~ ~s("delta":"Acknowledged.")
  end
end
