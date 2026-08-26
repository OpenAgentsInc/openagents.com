defmodule OpenAgents.UnpricedLane do
  @moduledoc """
  A catalog lane with no rates, for the tests that prove what `unpriced` means.

  `:model_catalog` shipped an unpriced lane for as long as `gpt-5.6-luna` was
  admitted, so every test that needed one reached for it. Withdrawing that
  model at owner direction left the invariant intact and the fixture gone:
  `OpenAgents.Inference.Pricing` still answers `unpriced`, `OpenAgents.Threads`
  still refuses to total a session that touched such a lane, and every read
  surface still shows the word rather than `$0.00` — but no shipped model is in
  that state to demonstrate it with.

  So the fixture is declared here rather than in the deployment's catalog. That
  is the honest arrangement: the production list says what this deployment
  actually serves, and a test that needs an unpriced lane says so itself.

  Only a synchronous test may use this. It rewrites application configuration,
  which every process in the node reads.
  """

  @id "test-unpriced-lane"

  @doc "The id of the lane this module admits."
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Admit an unpriced lane for the duration of one test.

  Returns the catalog that was in place, which the caller restores in
  `on_exit/1`.
  """
  @spec admit!() :: [map()]
  def admit! do
    previous = Application.fetch_env!(:openagents, :model_catalog)
    Application.put_env(:openagents, :model_catalog, previous ++ [entry()])
    previous
  end

  @doc "Put back the catalog `admit!/0` replaced."
  @spec restore([map()]) :: :ok
  def restore(previous), do: Application.put_env(:openagents, :model_catalog, previous)

  @doc "The lane itself: a routed model that deliberately declares no `pricing`."
  @spec entry() :: map()
  def entry do
    %{
      id: @id,
      provider: :openai,
      provider_model: @id,
      context_window: 272_000,
      max_output: 4_096
    }
  end
end
