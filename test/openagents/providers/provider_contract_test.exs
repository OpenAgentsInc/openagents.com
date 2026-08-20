defmodule OpenAgents.Providers.ProviderContractTest do
  use ExUnit.Case, async: true
  @moduletag :skip

  alias OpenAgents.Providers.{OpenAI, Test}

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
