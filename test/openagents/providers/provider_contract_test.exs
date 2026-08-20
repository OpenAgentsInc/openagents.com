defmodule OpenAgents.Providers.ProviderContractTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenAI, Request, Test}

  setup {Req.Test, :verify_on_exit!}

  test "providers expose stable IDs and finite provider-neutral capabilities" do
    for provider <- [OpenAI, Test] do
      assert provider.id() =~ ~r/^[a-z0-9.]+$/
      assert provider.capabilities() == Enum.uniq(provider.capabilities())
      assert Enum.all?(provider.capabilities(), &(&1 in [:text, :tool_calls, :usage]))
      assert :text in provider.capabilities()
    end
  end

  test "text-only providers remain valid without advertising tool calls" do
    assert __MODULE__.TextOnlyProvider.capabilities() == [:text]
  end

  test "response creation does not retry a failed POST without an idempotency contract" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    request = %Request{
      model_id: "test-model",
      instructions: "Bounded test instructions",
      input: [%{role: "user", content: "Hello"}]
    }

    assert {:error, {:http_status, 503}} =
             OpenAI.stream(request, fn _event -> :ok end,
               api_key: "test-secret",
               request_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  defmodule TextOnlyProvider do
    @behaviour OpenAgents.Providers.Provider

    @impl true
    def id, do: "text.only"

    @impl true
    def capabilities, do: [:text]

    @impl true
    def stream(_request, _on_event), do: {:error, {:provider_failed, "not_configured"}}
  end
end
