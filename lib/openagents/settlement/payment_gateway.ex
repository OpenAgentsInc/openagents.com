defmodule OpenAgents.Settlement.PaymentGateway do
  @moduledoc """
  The treasury payment boundary for bounty settlement.

  The settlement domain never holds custody, keys, or a node connection. It
  hands an authorized, idempotency-keyed request to the configured gateway —
  the self-custodial MoneyDevKit treasury path in production — and records
  whatever exact evidence comes back.

  A gateway reports one of three answers:

    * `{:ok, settled}` — the payment reached the destination, with
      `payment_hash`, `preimage_digest`, `fee_sats`, `paid_at`, and
      `gateway_ref`.
    * `{:pending, reason_code}` — the gateway accepted the request but has no
      terminal answer yet. The intent stays payable under the same key.
    * `{:error, reason_code}` — the attempt failed. A retry uses the same key.

  `lookup/1` answers the same shapes for a key that was already dispatched,
  which is how a lost acknowledgement reconciles without a second payment.
  """

  @type request :: %{
          idempotency_key: String.t(),
          amount_sats: pos_integer(),
          destination_kind: String.t(),
          destination: String.t(),
          memo: String.t()
        }

  @type settled :: %{
          payment_hash: String.t(),
          preimage_digest: String.t(),
          fee_sats: non_neg_integer(),
          paid_at: DateTime.t(),
          gateway_ref: String.t()
        }

  @type answer ::
          {:ok, settled()} | {:pending, String.t()} | {:error, String.t()} | {:unknown, nil}

  @callback pay(request()) :: answer()
  @callback lookup(String.t()) :: answer()

  @doc "The configured gateway module, fail-closed when unset."
  def gateway do
    Application.get_env(
      :openagents,
      :settlement_payment_gateway,
      OpenAgents.Settlement.PaymentGateway.Unconfigured
    )
  end

  @doc "Dispatches one authorized payment request."
  def pay(request), do: gateway().pay(request)

  @doc "Reads the terminal state of a previously dispatched key."
  def lookup(idempotency_key), do: gateway().lookup(idempotency_key)
end
