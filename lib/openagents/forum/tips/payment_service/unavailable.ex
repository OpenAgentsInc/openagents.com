defmodule OpenAgents.Forum.Tips.PaymentService.Unavailable do
  @moduledoc """
  The default payment service: none.

  Without an admitted service the forum refuses to start payments rather than
  pretending to move sats. Reads, totals, and ranking are unaffected.
  """

  @behaviour OpenAgents.Forum.Tips.PaymentService

  @impl true
  def pay(_request), do: {:error, :payment_service_unavailable}
end
