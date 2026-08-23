defmodule OpenAgents.Settlement.PaymentGateway.Unconfigured do
  @moduledoc """
  The default gateway: it refuses every payment.

  An environment without an admitted treasury gateway must fail closed rather
  than appear to pay. The refusal is a failed attempt on an existing intent, so
  configuring the real gateway and retrying the same idempotency key settles
  the original authorization instead of creating a second one.
  """

  @behaviour OpenAgents.Settlement.PaymentGateway

  @impl true
  def pay(_request), do: {:error, "payment_gateway_unconfigured"}

  @impl true
  def lookup(_idempotency_key), do: {:unknown, nil}
end
