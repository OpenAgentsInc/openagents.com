defmodule OpenAgentsWeb.BoxFanoutControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Conversations

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.merge(original_api || [],
        base_url: "https://box-api.internal",
        poll_interval_ms: 0,
        poll_attempts: 1,
        request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
      )
    )

    Application.put_env(:openagents, :box_api_key, "box-api-fanout-controller-test")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    :ok
  end

  test "returns a durable admission plan with labels and queue reasons", %{conn: conn} do
    user = github_user("api-token-box-fanout-controller")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    counter = start_supervised!({Agent, fn -> 0 end})
    box_ids = ["bx_ctlxxxxx", "bx_ctlxxxyy"]

    Req.Test.stub(__MODULE__, fn request ->
      case request.method do
        "POST" ->
          number = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
          Req.Test.json(request, box_body(Enum.at(box_ids, number - 1)))

        "GET" ->
          Req.Test.json(request, box_body("bx_ctlxxxxx"))
      end
    end)

    response =
      conn
      |> put_box_api_token("box-fanout-controller")
      |> post("/api/v3/conversations/#{conversation.id}/boxes/fanout", %{
        "count" => 3,
        "labels" => ["left", "middle", "right"]
      })
      |> json_response(202)

    assert response["plan"]["requested_count"] == 3
    assert length(response["plan"]["admitted"]) == 2
    assert Enum.all?(response["plan"]["admitted"], &is_binary(&1["box_id"]))

    assert [%{"label" => "right", "queue_reason" => "conversation_active_limit"}] =
             response["plan"]["queued"]
  end

  test "a foreign conversation is indistinguishable from a missing one", %{conn: conn} do
    owner = github_user("box-fanout-foreign-owner")
    foreign = github_user("box-fanout-foreign-account")
    {:ok, conversation} = Conversations.ensure_conversation(owner)

    Req.Test.stub(__MODULE__, fn _request ->
      flunk("foreign conversation must not contact the provider")
    end)

    response =
      conn
      |> put_box_api_token("box-fanout-foreign-account")
      |> post("/api/v3/conversations/#{conversation.id}/boxes/fanout", %{"count" => 1})
      |> json_response(404)

    assert response == %{"error" => %{"code" => "conversation_not_found"}}
    assert foreign.id != owner.id
  end

  defp box_body(box_id) do
    %{"box" => %{"id" => box_id, "state" => "ready", "setupStatus" => "done"}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
