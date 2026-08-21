defmodule OpenAgents.Analytics.PostHogSink do
  @moduledoc """
  The production analytics sink: the `posthog` Hex package.

  The package batches events and flushes them from its own supervision tree,
  which `OpenAgents.Application` starts only when a project token is
  configured. Events carry the distinct ID as a property, per the package API.
  """

  @spec capture(OpenAgents.Analytics.event_name(), OpenAgents.Analytics.distinct_id(), map()) ::
          term()
  def capture(event, distinct_id, properties) do
    PostHog.capture(event, Map.put(properties, :distinct_id, distinct_id))
  end
end
