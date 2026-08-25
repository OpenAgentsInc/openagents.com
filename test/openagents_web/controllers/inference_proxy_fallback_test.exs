defmodule OpenAgentsWeb.InferenceProxyFallbackTest do
  @moduledoc """
  What a metered call says when a fallback served it.

  `config :openagents, :vercel_gateway_fallback_models` tells Vercel to answer a
  failed `google/gemini-3.7-flash` call with `openai/gpt-5.6-luna` and still
  return 200. The adapter never read back which model answered, so the usage
  record was priced against Gemini's rates for a call Luna served, the thread's
  cost totalled as though it were known, and the Gemini lane was recorded
  healthy on the strength of a call it did not serve (METER-001, PROVIDER-002).
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Inference.Health
  alias OpenAgents.Inference.Models
  alias OpenAgents.Inference.Pricing
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  @gemini "gemini-3.7-flash"

  setup do
    previous = Application.get_env(:openagents, :vercel_gateway_provider)

    Application.put_env(
      :openagents,
      :vercel_gateway_provider,
      OpenAgents.Providers.FallbackTestProvider
    )

    Health.reset()

    on_exit(fn ->
      Application.put_env(:openagents, :vercel_gateway_provider, previous)
      Application.delete_env(:openagents, :test_fallback_served_model)
      Health.reset()
    end)

    :ok
  end

  defp serve_as(name), do: Application.put_env(:openagents, :test_fallback_served_model, name)

  defp disclose_nothing, do: Application.delete_env(:openagents, :test_fallback_served_model)

  defp gemini_grant(key) do
    owner = github_user("fallback-#{key}")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, grant, token} =
      Inference.mint(%{
        owner_visitor_id: conversation.visitor_id,
        conversation_id: conversation.id,
        model_id: @gemini
      })

    %{grant: grant, token: token}
  end

  defp call(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/api/inference/proxy",
      Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hello"}]})
    )
  end

  describe "a call a fallback model served" do
    test "is priced against the model that served it, not the one requested", %{conn: conn} do
      # The requested lane has rates; the lane Vercel fell back to has none.
      # Pricing the call at the requested lane's rates is the bug: it produces
      # a figure, and the figure is for a call that never ran there.
      assert Pricing.basis(@gemini) == "provisional"
      serve_as("openai/gpt-5.6-luna")

      %{grant: grant, token: token} = gemini_grant("priced")
      assert call(conn, token).status == 200

      metered = Repo.get(Grant, grant.id)

      assert metered.usage["served_model"] == "openai/gpt-5.6-luna"
      assert metered.usage["pricing_id"] == Pricing.unpriced()
      refute Map.has_key?(metered.usage, "estimated_cost_microusd")
      assert Pricing.cost(metered.usage) == nil
    end

    test "is attributed to the model that served it on the response", %{conn: conn} do
      serve_as("openai/gpt-5.6-luna")
      %{token: token} = gemini_grant("attributed")

      conn = call(conn, token)

      assert get_resp_header(conn, "x-openagents-model") == ["openai/gpt-5.6-luna"]

      for chunk <- String.split(conn.resp_body, "\n\n", trim: true),
          chunk != "data: [DONE]" do
        payload = chunk |> String.replace_prefix("data: ", "") |> Jason.decode!()
        assert payload["model"] == "openai/gpt-5.6-luna"
      end
    end

    test "counts against the requested lane's health, not for it", %{conn: conn} do
      # `GET /api/v1/models` publishes availability from this. A lane that was
      # rescued by a fallback did not answer, and recording it healthy is the
      # same class of lie that #238 fixed: every call to a dead lane would keep
      # reporting `available` forever, because the fallback kept rescuing it.
      luna = Application.fetch_env!(:openagents, :openai_model)
      serve_as(luna)
      {:ok, gemini} = Models.fetch(@gemini)

      for index <- 1..Health.degraded_after() do
        %{token: token} = gemini_grant("health-#{index}")
        assert call(conn, token).status == 200
      end

      assert Models.availability(gemini) == "degraded"
      assert Health.status(luna) == {:healthy, nil}
    end

    test "makes the thread's cost unpriced, and names the lane that made it so", %{conn: _conn} do
      # METER-001's contract, end to end: a thread whose only call was served
      # by an unpriced fallback reports no total at all rather than a total at
      # the requested model's rates.
      user = github_user("fallback-thread")
      {:ok, thread, grant, _token} = Threads.open_and_mint(user, "Fallback lane")
      assert grant.model_id == @gemini

      {:ok, _metered} =
        Inference.record_usage(
          grant,
          %{"input_tokens" => 1_000_000, "output_tokens" => 100_000},
          "openai/gpt-5.6-luna"
        )

      spend = Threads.spend(thread)

      assert spend.calls == 1
      refute spend.cost.microusd == 0
      assert spend.cost.microusd == nil
      assert spend.cost.basis == "unpriced"
      assert spend.cost.unpriced_calls == 1
      assert spend.cost.unpriced_models == ["openai/gpt-5.6-luna"]
    end
  end

  describe "a call whose serving model the response did not disclose" do
    test "is recorded unresolved and priced at nothing", %{conn: conn} do
      disclose_nothing()
      %{grant: grant, token: token} = gemini_grant("silent")

      conn = call(conn, token)
      assert conn.status == 200

      metered = Repo.get(Grant, grant.id)

      # The lane can substitute and the answer said nothing, so what served it
      # is unknown. Recording the requested model here would be inventing the
      # one fact the record exists to carry.
      assert metered.usage["served_model"] == Inference.unresolved_model()
      assert metered.usage["pricing_id"] == Pricing.unpriced()
      refute Map.has_key?(metered.usage, "estimated_cost_microusd")
      assert get_resp_header(conn, "x-openagents-model") == [Inference.unresolved_model()]
    end

    test "records no health for the requested lane either way", %{conn: conn} do
      disclose_nothing()
      %{token: token} = gemini_grant("silent-health")

      assert call(conn, token).status == 200

      # Neither healthy nor degraded: nothing here knows whether that lane ran.
      assert Health.status(@gemini) == {:unknown, nil}
    end
  end

  describe "a call the requested model served" do
    test "is priced and attributed as it always was, by either spelling", %{conn: conn} do
      # The gateway names the vendor spelling; the catalog names the public id.
      # They are one model, and reading them as two would make every Gemini
      # call unpriced.
      {:ok, gemini} = Models.fetch(@gemini)
      serve_as(gemini.provider_model)

      %{grant: grant, token: token} = gemini_grant("same")
      conn = call(conn, token)

      assert get_resp_header(conn, "x-openagents-model") == [@gemini]

      metered = Repo.get(Grant, grant.id)
      assert metered.usage["served_model"] == @gemini
      assert metered.usage["pricing_id"] == "placeholder.gemini-3.7-flash.v1"
      assert Pricing.cost(metered.usage) > 0
      assert Health.status(@gemini) == {:healthy, nil}
    end
  end

  describe "a grant whose calls were served by more than one model" do
    test "reports a mixed record and no total" do
      # Two rate tables, one accumulated sum. Charging it at either rate would
      # be a guess, so the record says so and prices nothing.
      user = github_user("fallback-mixed")
      {:ok, _thread, grant, _token} = Threads.open_and_mint(user, "Mixed lanes")

      {:ok, first} = Inference.record_usage(grant, %{"input_tokens" => 1_000}, :requested)
      assert first.usage["served_model"] == @gemini
      assert Pricing.cost(first.usage) > 0

      {:ok, second} =
        Inference.record_usage(first, %{"input_tokens" => 1_000}, "openai/gpt-5.6-luna")

      assert second.usage["served_model"] == Inference.mixed_model()
      assert second.usage["pricing_id"] == Pricing.unpriced()
      assert Pricing.cost(second.usage) == nil
    end
  end

  test "the reserved names are not names the catalog could serve" do
    # `unresolved` and `mixed` price at nothing because the catalog does not
    # resolve them. A model that took either name would be priced by accident.
    reserved = [Inference.unresolved_model(), Inference.mixed_model()]

    for model <- Models.all() do
      refute model.id in reserved
      refute model.provider_model in reserved
    end
  end
end
