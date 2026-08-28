defmodule OpenAgents.Providers.VercelGatewayTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.VercelGateway

  describe "provider routing" do
    test "sends the gateway the provider order this deployment intends" do
      # The same Gemini slug is served by `google` — the Generative Language
      # endpoint — and by `vertex`, which is where this account's credits are.
      # `order` tries Vertex first and lets Vercel move to other providers
      # for the configured fallback models.
      assert VercelGateway.payload_extra() == %{providerOptions: %{gateway: %{order: ["vertex"]}}}
    end

    test "sends no provider or model options when none are configured" do
      previous = Application.get_env(:openagents, :vercel_gateway_providers)
      Application.put_env(:openagents, :vercel_gateway_providers, [])
      on_exit(fn -> Application.put_env(:openagents, :vercel_gateway_providers, previous) end)

      # An empty `order` would be a pin to nothing, which the gateway is entitled
      # to read as "no provider may serve this".
      assert VercelGateway.payload_extra() == %{}
    end

    test "sends the fallback model list when configured" do
      previous = Application.get_env(:openagents, :vercel_gateway_fallback_models)

      Application.put_env(:openagents, :vercel_gateway_fallback_models, [
        "zai/glm-5.3",
        "openai/gpt-5.6-luna"
      ])

      on_exit(fn ->
        Application.put_env(:openagents, :vercel_gateway_fallback_models, previous)
      end)

      assert VercelGateway.payload_extra() == %{
               providerOptions: %{
                 gateway: %{
                   order: ["vertex"],
                   models: ["zai/glm-5.3", "openai/gpt-5.6-luna"]
                 }
               }
             }

      assert VercelGateway.payload_extra(allow_fallback: true) == VercelGateway.payload_extra()
    end

    test "omits the fallback model list when the grant pinned a model" do
      previous = Application.get_env(:openagents, :vercel_gateway_fallback_models)

      Application.put_env(:openagents, :vercel_gateway_fallback_models, [
        "zai/glm-5.3-flash",
        "zai/glm-5.3",
        "openai/gpt-5.6-luna"
      ])

      on_exit(fn ->
        Application.put_env(:openagents, :vercel_gateway_fallback_models, previous)
      end)

      # Vertex `order` stays; `models` is the instruction to substitute, and a
      # pin must not send it (#258).
      assert VercelGateway.payload_extra(allow_fallback: false) == %{
               providerOptions: %{gateway: %{order: ["vertex"]}}
             }
    end
  end

  # METER-001, PROVIDER-002. The fallback list is an instruction to answer a
  # failed call with a different model, so this lane's request is not evidence
  # of what served it. Saying so is what makes the host read an undisclosed
  # model as unresolved rather than as the model it asked for.
  describe "whether this lane can be substituted for" do
    setup do
      previous = Application.get_env(:openagents, :vercel_gateway_fallback_models)

      on_exit(fn ->
        Application.put_env(:openagents, :vercel_gateway_fallback_models, previous)
      end)

      :ok
    end

    test "is true exactly while a fallback list is configured" do
      Application.put_env(:openagents, :vercel_gateway_fallback_models, ["openai/gpt-5.6-luna"])
      assert VercelGateway.substitutable?()

      Application.put_env(:openagents, :vercel_gateway_fallback_models, [])
      refute VercelGateway.substitutable?()
    end
  end

  describe "the credential" do
    test "is its own, not OpenRouter's" do
      previous = Application.get_env(:openagents, :vercel_gateway_api_key)
      Application.put_env(:openagents, :vercel_gateway_api_key, nil)
      on_exit(fn -> Application.put_env(:openagents, :vercel_gateway_api_key, previous) end)

      refute VercelGateway.configured?()

      Application.put_env(:openagents, :vercel_gateway_api_key, "vck_test")
      assert VercelGateway.configured?()
    end
  end

  test "speaks chat completions, and says so" do
    assert VercelGateway.id() == "vercel_gateway.chat_completions"
    assert :tool_calls in VercelGateway.capabilities()
  end
end
