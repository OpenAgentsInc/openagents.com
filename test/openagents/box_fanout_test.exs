defmodule OpenAgents.BoxFanoutTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.{Conversations, Repo}
  alias OpenAgents.Box
  alias OpenAgents.Box.{Fanout, FanoutItem}

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

    Application.put_env(:openagents, :box_api_key, "box-api-fanout-test")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    {:ok, conversation} = Conversations.ensure_conversation("box-fanout-owner")
    %{conversation_id: conversation.id}
  end

  test "admits up to the default cap and queues the remainder in order", %{
    conversation_id: conversation_id
  } do
    expect_create("bx_fanxxxyy")
    expect_create("bx_fanxxxxx")

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 3,
               labels: ["alpha", "beta", "gamma"]
             )

    assert plan.admitted_count == 2
    assert plan.queued_count == 1

    assert Enum.map(plan.items, &{&1.position, &1.label, &1.state}) == [
             {0, "alpha", "admitted"},
             {1, "beta", "admitted"},
             {2, "gamma", "queued"}
           ]

    assert Enum.all?(plan.items, &(&1.requesting_principal == %{"type" => "user"}))

    assert Enum.at(plan.items, 2).queue_reason == "conversation_active_limit"
  end

  test "a budgeted request raises only its own conversation cap", %{
    conversation_id: conversation_id
  } do
    for box_id <- ~w(bx_budxxyyy bx_budxxxyy bx_budxxxxx) do
      expect_create(box_id)
    end

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user", "id" => "requester"}, 3,
               labels: ["one", "two", "three"],
               budgeted: true
             )

    assert plan.admitted_count == 3
    assert plan.queued_count == 0
    assert plan.effective_limits["conversation_active_limit"] == 10
    assert plan.effective_limits["budgeted"] == true
  end

  test "a budgeted request queues beyond the configured ceiling", %{
    conversation_id: conversation_id
  } do
    with_capacity_limits(maximum_burn_rate_per_conversation_microusd: 2_000_000)

    for number <- 1..10, do: expect_create(dynamic_box_id(number))

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user", "id" => "requester"}, 11,
               budgeted: true
             )

    assert plan.admitted_count == 10
    assert plan.queued_count == 1

    assert [%{position: 10, queue_reason: "conversation_active_limit"}] =
             Enum.filter(plan.items, &(&1.state == "queued"))
  end

  test "refuses duplicate labels before contacting the provider", %{
    conversation_id: conversation_id
  } do
    assert {:error, :box_label_taken} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 2, labels: ["same", "same"])

    assert Repo.aggregate(FanoutItem, :count) == 0
  end

  test "promotes the oldest queued item when a box stops", %{conversation_id: conversation_id} do
    expect_create("bx_prmxxxyy")
    expect_create("bx_prmxxxxx")

    assert {:ok, first} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 3,
               labels: ["first", "second", "third"]
             )

    expect_stop("bx_prmxxxyy")
    expect_create("bx_prmxxyyy")

    assert {:ok, _stopped} = Box.stop_box(conversation_id, Enum.at(first.items, 0).label)
    assert {:ok, plan} = Fanout.get(conversation_id, first.id)
    assert Enum.at(plan.items, 0).state == "admitted"
    assert Enum.at(plan.items, 1).state == "admitted"
  end

  test "queues provider billing failures and does not continue the plan", %{
    conversation_id: conversation_id
  } do
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/boxes"} ->
          call_number = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

          if call_number == 1 do
            Req.Test.json(conn, box_body("bx_bilxxxxx"))
          else
            conn
            |> Plug.Conn.put_status(402)
            |> Req.Test.json(%{"code" => "billing_required"})
          end

        {"GET", "/boxes/bx_bilxxxxx"} ->
          Req.Test.json(conn, box_body("bx_bilxxxxx"))
      end
    end)

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 3,
               labels: ["first", "second", "third"]
             )

    assert Enum.map(plan.items, &{&1.label, &1.queue_reason}) == [
             {"first", nil},
             {"second", "provider_billing_required"},
             {"third", "provider_billing_required"}
           ]
  end

  test "generated labels remain stable and can identify a box", %{
    conversation_id: conversation_id
  } do
    expect_create("bx_stabxxxx")
    assert {:ok, record} = Box.create_box(conversation_id)
    assert record.label == "box-1"
    expect_get("bx_stabxxxx")
    assert {:ok, found} = Box.get_box(conversation_id, record.label)
    assert found.id == record.id
    assert found.label == record.label

    expect_stop("bx_stabxxxx")
    assert {:ok, _stopped} = Box.stop_box(conversation_id, record.label)

    expect_create("bx_stabxxxy")
    assert {:ok, next_record} = Box.create_box(conversation_id)
    assert next_record.label == "box-2"
  end

  test "queues at the conversation burn-rate ceiling", %{conversation_id: conversation_id} do
    original_api = Application.get_env(:openagents, :box_api)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.put(original_api, :maximum_burn_rate_per_conversation_microusd, 150_000)
    )

    on_exit(fn -> Application.put_env(:openagents, :box_api, original_api) end)

    expect_create("bx_spendxxx")

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 2, labels: ["within", "over"])

    assert plan.admitted_count == 1

    assert [%{label: "over", queue_reason: "conversation_burn_rate_ceiling"}] =
             Enum.filter(plan.items, &(&1.state == "queued"))
  end

  test "queues at the owner burn-rate ceiling" do
    user = repository_user_fixture("box-fanout-owner-burn-rate")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    with_capacity_limits(
      maximum_burn_rate_per_conversation_microusd: 2_000_000,
      maximum_burn_rate_per_owner_microusd: 150_000
    )

    box_id = dynamic_box_id(42)
    expect_create(box_id)

    assert {:ok, plan} =
             Fanout.admit(conversation.id, %{"type" => "user"}, 2,
               labels: ["within-owner-budget", "over-owner-budget"]
             )

    assert plan.admitted_count == 1

    assert [%{queue_reason: "owner_burn_rate_ceiling"}] =
             Enum.filter(plan.items, &(&1.state == "queued"))
  end

  test "queues provider rate limiting and preserves the remainder", %{
    conversation_id: conversation_id
  } do
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "POST" ->
          number = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

          if number == 1 do
            Req.Test.json(conn, box_body("bx_ratexxxx"))
          else
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{"code" => "rate_limited"})
          end

        "GET" ->
          Req.Test.json(conn, box_body("bx_ratexxxx"))
      end
    end)

    assert {:ok, plan} =
             Fanout.admit(conversation_id, %{"type" => "user"}, 3,
               labels: ["first", "second", "third"]
             )

    assert Enum.map(plan.items, &{&1.state, &1.queue_reason}) == [
             {"admitted", nil},
             {"queued", "provider_rate_limited"},
             {"queued", "provider_rate_limited"}
           ]
  end

  test "concurrent requests never exceed the conversation cap", %{
    conversation_id: conversation_id
  } do
    with_capacity_limits(default_maximum_active_boxes: 2, maximum_active_boxes_per_owner: 100)
    stub_dynamic_provider()

    results =
      concurrently(3, fn index ->
        Fanout.admit(conversation_id, %{"type" => "user"}, 1,
          labels: ["concurrent-conversation-#{index}"]
        )
      end)

    assert Enum.count(results, &match?({:ok, %{admitted_count: 1}}, &1)) == 2
    assert Enum.count(results, &match?({:ok, %{queued_count: 1}}, &1)) == 1
  end

  test "concurrent requests never exceed the conversation burn-rate ceiling", %{
    conversation_id: conversation_id
  } do
    with_capacity_limits(
      default_maximum_active_boxes: 10,
      maximum_active_boxes_per_owner: 100,
      maximum_active_boxes_global: 100,
      maximum_burn_rate_per_conversation_microusd: 150_000
    )

    stub_dynamic_provider()

    results =
      concurrently(2, fn index ->
        Fanout.admit(conversation_id, %{"type" => "user"}, 1,
          labels: ["concurrent-burn-rate-#{index}"]
        )
      end)

    assert Enum.count(results, &match?({:ok, %{admitted_count: 1}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{queued_count: 1}}, &1)) == 1

    assert Enum.any?(results, fn
             {:ok, %{items: [%{queue_reason: "conversation_burn_rate_ceiling"}]}} -> true
             _result -> false
           end)
  end

  test "concurrent requests never exceed the owner cap" do
    user = repository_user_fixture("box-fanout-owner-cap")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    with_capacity_limits(
      default_maximum_active_boxes: 10,
      maximum_active_boxes_per_owner: 2,
      maximum_active_boxes_global: 100
    )

    stub_dynamic_provider()

    results =
      concurrently(3, fn index ->
        Fanout.admit(conversation.id, %{"type" => "user"}, 1,
          labels: ["concurrent-owner-#{index}"]
        )
      end)

    assert Enum.count(results, &match?({:ok, %{admitted_count: 1}}, &1)) == 2
    assert Enum.count(results, &match?({:ok, %{queued_count: 1}}, &1)) == 1
  end

  test "concurrent requests never exceed the global cap" do
    conversations =
      for index <- 1..3 do
        {:ok, conversation} = Conversations.ensure_conversation("global-cap-#{index}")
        conversation.id
      end

    with_capacity_limits(
      default_maximum_active_boxes: 10,
      maximum_active_boxes_per_owner: 100,
      maximum_active_boxes_global: 2
    )

    stub_dynamic_provider()

    results =
      conversations
      |> Enum.with_index()
      |> concurrently(fn {conversation_id, index} ->
        Fanout.admit(conversation_id, %{"type" => "user"}, 1,
          labels: ["concurrent-global-#{index}"]
        )
      end)

    assert Enum.count(results, &match?({:ok, %{admitted_count: 1}}, &1)) == 2
    assert Enum.count(results, &match?({:ok, %{queued_count: 1}}, &1)) == 1
  end

  defp expect_create(box_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/boxes"
      Req.Test.json(conn, box_body(box_id))
    end)

    expect_get(box_id)
  end

  defp expect_get(box_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/boxes/#{box_id}"
      Req.Test.json(conn, box_body(box_id))
    end)
  end

  defp expect_stop(box_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/boxes/#{box_id}/stop"
      Req.Test.json(conn, box_body(box_id, %{"state" => "archiving"}))
    end)
  end

  defp with_capacity_limits(overrides) do
    original_api = Application.get_env(:openagents, :box_api)
    Application.put_env(:openagents, :box_api, Keyword.merge(original_api, overrides))
    on_exit(fn -> Application.put_env(:openagents, :box_api, original_api) end)
  end

  defp stub_dynamic_provider do
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "POST" ->
          number = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
          Req.Test.json(conn, box_body(dynamic_box_id(number)))

        "GET" ->
          box_id = conn.request_path |> String.split("/") |> List.last()
          Req.Test.json(conn, box_body(box_id))
      end
    end)
  end

  defp concurrently(collection, fun) when is_list(collection) do
    parent = self()

    collection
    |> Task.async_stream(
      fn item ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        fun.(item)
      end,
      max_concurrency: length(collection),
      ordered: true,
      timeout: 30_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp concurrently(count, fun) when is_integer(count) do
    concurrently(Enum.to_list(1..count), fun)
  end

  defp dynamic_box_id(number) do
    alphabet = ~c"23456789abcdefghjkmnpqrstuvwxyz"

    suffix =
      number
      |> Integer.digits(length(alphabet))
      |> Enum.map(&Enum.at(alphabet, &1))
      |> to_string()

    "bx_" <> String.pad_leading(suffix, 8, "2")
  end

  defp box_body(box_id, overrides \\ %{}) do
    %{
      "box" =>
        Map.merge(
          %{"id" => box_id, "state" => "ready", "setupStatus" => "done"},
          overrides
        )
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
