defmodule OpenAgents.Notifications.Delivery.NullAdapter do
  @moduledoc """
  Default no-op email delivery adapter.

  No provider is configured, so a delivery that has a recipient cannot be sent.
  The handler returns an error and the durable outbox retries up to its
  `maximum_attempts`. A delivery without a recipient is handled before the
  adapter is ever called.
  """

  @behaviour OpenAgents.Notifications.Delivery.Adapter

  @impl true
  def deliver(_recipient, _data), do: {:error, :no_provider_configured}
end
