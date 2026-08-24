defmodule OpenAgents.Providers.UnconfiguredTestProvider do
  @moduledoc """
  A provider whose credential is not configured, for PROVIDER-002 tests.

  Swapped into a lane's configuration to drive the unavailable branch: the
  catalog must list the lane's models as `unavailable`, and admission and the
  proxy must refuse them with `model_unavailable` before any call is made —
  which is why `stream/2` raises rather than answers.
  """

  @behaviour OpenAgents.Providers.Provider

  @impl true
  def id, do: "test.unconfigured_provider"

  @impl true
  def capabilities, do: [:text]

  @impl true
  def configured?, do: false

  @impl true
  def stream(_request, _on_event) do
    raise "an unavailable model must be refused before its provider is called"
  end
end
