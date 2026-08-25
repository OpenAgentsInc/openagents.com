defmodule OpenAgents.Providers.FailingTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.Request

  @impl true
  def id, do: "test.failing_provider"

  @impl true
  def capabilities, do: [:text]

  @impl true
  def configured?, do: true

  # One delta lands, then the provider dies: the case a streaming surface
  # must answer with its failure shape rather than a silent half-answer.
  @impl true
  def stream(%Request{}, on_event) when is_function(on_event, 1) do
    on_event.({:response_started, "failing-response"})
    on_event.({:text_delta, "half an "})
    {:error, :upstream_5xx}
  end
end
