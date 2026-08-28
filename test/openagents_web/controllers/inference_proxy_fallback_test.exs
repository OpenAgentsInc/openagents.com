defmodule OpenAgentsWeb.InferenceProxyFallbackTest do
  @moduledoc """
  What a metered call says when a fallback served it.

  `config :openagents, :vercel_gateway_fallback_models` tells Vercel to answer a
  failed primary with `openai/gpt-5.6-luna` and still return 200 — but only
  unnamed-model selection may send that list. A grant that named a model is a
  pin; fallback on that call is a miss even when the substitute is attributed
  honestly (#258). Unnamed selection still reads the serving model back so a
  rescued call is priced against the lane that ran, not the one that was asked
  for (METER-001, PROVIDER-002).
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

  # Neither the mint nor the body names a model, so the proxy may still attach
  # the gateway fallback list (#258).
  defp unnamed_grant(key) do
    owner = github_user("fallback-#{key}")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, grant, token} =
      Inference.mint(%{
        owner_visitor_id: conversation.visitor_id,
        conversation_id: conversation.id
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

  describe "a pinned grant a fallback model served" do
    test "is not a successful turn", %{conn: conn} do
      # Explore pins `gemini-3.7-flash`. Answering with GLM and calling that
      # 200 is the miss even when the substitute is a catalog model (#258).
      serve_as("zai/glm-5.3-flash")
      %{grant: grant, token: token} = gemini_grant("pinned-glm")

      conn = call(conn, token)
      refute conn.status == 200

      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == "model_substituted"
      assert error["granted"] == @gemini
      assert error["served"] == "glm-5.3-flash"

      metered = Repo.get(Grant, grant.id)
      refute metered.usage["served_model"] == @gemini
    end
  end

  describe "a call a fallback model served" do
    test "is priced against the model that served it, not the one requested", %{conn: conn} do
      # The requested lane has rates; the lane Vercel fell back to has none.
      # Pricing the call at the requested lane's rates is the bug: it produces
      # a figure, and the figure is for a call that never ran there.
      serve_as("openai/gpt-5.6-luna")

      %{grant: grant, token: token} = unnamed_grant("priced")
      assert call(conn, token).status == 200

      metered = Repo.get(Grant, grant.id)

      assert metered.usage["served_model"] == "openai/gpt-5.6-luna"
      assert metered.usage["pricing_id"] == Pricing.unpriced()
      refute Map.has_key?(metered.usage, "estimated_cost_microusd")
      assert Pricing.cost(metered.usage) == nil
    end

    test "is attributed to the model that served it on the response", %{conn: conn} do
      serve_as("openai/gpt-5.6-luna")
      %{grant: grant, token: token} = unnamed_grant("attributed")

      conn = call(conn, token)

      # The stream (#263) opens before any provider event, so the header names
      # the lane the call addressed. The disclosure corrects the attribution on
      # the response body itself — every chunk carries the model that answered.
      assert get_resp_header(conn, "x-openagents-model") == [grant.model_id]

      chunks =
        for chunk <- String.split(conn.resp_body, "\n\n", trim: true),
            chunk != "data: [DONE]" do
          chunk |> String.replace_prefix("data: ", "") |> Jason.decode!()
        end

      for payload <- chunks do
        assert payload["model"] == "openai/gpt-5.6-luna"
      end

      # The first frame is the disclosure event's own neighbour, not a text
      # chunk: a silent disclosure still corrects everything on the wire after
      # it, including the terminal finish and usage frames.
      assert length(chunks) >= 2
    end

    test "counts against the requested lane's health, not for it", %{conn: conn} do
      # `GET /api/v1/models` publishes availability from this. A lane that was
      # rescued by a fallback did not answer, and recording it healthy is the
      # same class of lie that #238 fixed: every call to a dead lane would keep
      # reporting `available` forever, because the fallback kept rescuing it.
      luna = "openai/gpt-5.6-luna"
      serve_as(luna)
      {:ok, selected} = Models.fetch(Models.default_id())

      for index <- 1..Health.degraded_after() do
        %{token: token} = unnamed_grant("health-#{index}")
        assert call(conn, token).status == 200
      end

      assert Models.availability(selected) == "degraded"

      # Nothing is recorded for the lane that actually answered either. It is
      # not a model this deployment admits, so there is no lane to credit.
      assert Health.status(luna) == {:unknown, nil}
    end

    test "makes the thread's cost unpriced, and names the lane that made it so", %{conn: _conn} do
      # METER-001's contract, end to end: a thread whose only call was served
      # by an unpriced fallback reports no total at all rather than a total at
      # the requested model's rates.
      user = github_user("fallback-thread")

      {:ok, thread, grant, _token} =
        Threads.open_and_mint(user, "Fallback lane", model: @gemini)

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
      %{grant: grant, token: token} = unnamed_grant("silent")

      conn = call(conn, token)
      assert conn.status == 200

      metered = Repo.get(Grant, grant.id)

      # The lane can substitute and the answer said nothing, so what served it
      # is unknown. Recording the requested model here would be inventing the
      # one fact the record exists to carry.
      assert metered.usage["served_model"] == Inference.unresolved_model()
      assert metered.usage["pricing_id"] == Pricing.unpriced()
      refute Map.has_key?(metered.usage, "estimated_cost_microusd")

      # The stream opens before any provider event, so the header names the
      # lane the call addressed; with the answer silent there is nothing to
      # correct it with, and naming `unresolved` there would require buffering
      # the whole stream again (#263). The unresolved attribution lives where
      # the record is: the metered usage above.
      assert get_resp_header(conn, "x-openagents-model") == [grant.model_id]
    end

    test "records no health for the requested lane either way", %{conn: conn} do
      disclose_nothing()
      %{grant: grant, token: token} = unnamed_grant("silent-health")

      assert call(conn, token).status == 200

      # Neither healthy nor degraded: nothing here knows whether that lane ran.
      assert Health.status(grant.model_id) == {:unknown, nil}
    end

    test "is not a successful turn when the grant pinned a model", %{conn: conn} do
      disclose_nothing()
      %{token: token} = gemini_grant("silent-pin")

      conn = call(conn, token)
      refute conn.status == 200
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "model_substituted"
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

      assert metered.usage["pricing_id"] ==
               "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"

      assert Pricing.cost(metered.usage) > 0
      assert Health.status(@gemini) == {:healthy, nil}
    end
  end

  describe "a grant whose calls were served by more than one model" do
    test "reports a mixed record and no total" do
      # Two rate tables, one accumulated sum. Charging it at either rate would
      # be a guess, so the record says so and prices nothing.
      user = github_user("fallback-mixed")

      {:ok, _thread, grant, _token} =
        Threads.open_and_mint(user, "Mixed lanes", model: @gemini)

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
