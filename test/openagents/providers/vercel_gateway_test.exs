defmodule OpenAgents.Providers.VercelGatewayTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.VercelGateway

  describe "pinning the provider" do
    test "sends the gateway the provider set this deployment intends" do
      # The same Gemini slug is served by `google` — the Generative Language
      # endpoint — and by `vertex`, which is where this account's credits are.
      # Without the pin, a fallback spends money beside a balance already paid
      # for, and nothing in the response would say so.
      assert VercelGateway.payload_extra() == %{providerOptions: %{gateway: %{only: ["vertex"]}}}
    end

    test "sends no pin at all when none is configured, rather than an empty one" do
      previous = Application.get_env(:openagents, :vercel_gateway_providers)
      Application.put_env(:openagents, :vercel_gateway_providers, [])
      on_exit(fn -> Application.put_env(:openagents, :vercel_gateway_providers, previous) end)

      # An empty `only` would be a pin to nothing, which the gateway is entitled
      # to read as "no provider may serve this".
      assert VercelGateway.payload_extra() == %{}
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
