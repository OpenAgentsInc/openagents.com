defmodule OpenAgents.Notifications.Delivery.NullAdapter do
  @moduledoc """
  The adapter a deployment that configured none gets.

  It refuses every send, so a delivery that reached it — meaning the account
  confirmed an address and asked for mail — is retried by the durable outbox
  and then recorded as terminally failed rather than quietly dropped. A
  deployment in that state should be saying so on the settings surface too:
  `OpenAgents.Notifications.EmailChannel.deliverable?/0` is the switch that
  stops an address being collected in the first place.
  """

  @behaviour OpenAgents.Notifications.Delivery.Adapter

  @impl true
  def deliver(_recipient, _data), do: {:error, :no_provider_configured}
end
