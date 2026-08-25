defmodule OpenAgents.Settlement.PaymentGateway.Simulated do
  @moduledoc """
  A simulated bounty payment rail. No money moves and no key is held.

  The shipped alternative is `OpenAgents.Settlement.PaymentGateway.Unconfigured`,
  which refuses every request. That is correct for production and useless for a
  proof: with only those two, the settlement loop can be driven end to end
  nowhere except inside a private test module. This gateway exists so one
  sats-priced bounty can be driven from pricing through an accepted claim to a
  receipt, on a rail whose every artifact says on its face that it is simulated.

  What it is not: it opens no node connection, holds no key, custodies nothing,
  and reads no destination beyond checking that one is present. A `bolt12_offer`
  handed to it is never dialled. The evidence it returns is a hash of the
  idempotency key, not a preimage anyone can claim against a real invoice.

  Three properties make it safe to ship:

    * **It refuses in production.** `runtime_environment: :production` gets
      `{:error, "simulated_gateway_refused_in_production"}`, so pointing the
      live treasury at this module fakes no payment — it fails the attempt.
    * **Its evidence is marked.** Every `gateway_ref` starts with `simulated:`,
      so a receipt row minted here can never be mistaken for one a real rail
      produced, in the database or in an export.
    * **It is idempotent by construction.** The payment hash is derived from the
      idempotency key alone, so a replayed dispatch produces the identical hash
      and the unique `settlement_payment_receipts.payment_hash` constraint
      refuses the second receipt. Simulation cannot double-pay even by accident.

  `lookup/1` answers `{:unknown, nil}` for every key, because this rail keeps no
  ledger and will not vouch for a key it cannot see. That makes the
  lost-acknowledgement path unreachable here by design; `SETTLEMENT-001` proves
  reconciliation separately in `test/openagents/settlement_test.exs`.

  It moves no sats, so it proves the authority chain, not the transfer. The
  transfer stays on the self-custodial MoneyDevKit treasury path, which this
  repository does not implement.
  """

  @behaviour OpenAgents.Settlement.PaymentGateway

  alias OpenAgents.Provenance.Canonical

  @hash_domain "openagents.settlement.simulated.payment-hash.v1:"
  @preimage_domain "openagents.settlement.simulated.preimage.v1:"

  @doc "The prefix every simulated `gateway_ref` carries."
  def gateway_ref_prefix, do: "simulated:"

  @impl true
  def pay(request) do
    if admitted?() do
      settle(request)
    else
      {:error, "simulated_gateway_refused_in_production"}
    end
  end

  @impl true
  def lookup(_idempotency_key), do: {:unknown, nil}

  @doc """
  Whether this rail will answer at all.

  False in production, so the fail-closed posture survives a misconfiguration
  rather than depending on nobody making one.
  """
  def admitted?, do: Application.get_env(:openagents, :runtime_environment) != :production

  defp settle(request) when is_map(request) do
    with {:ok, key} <- idempotency_key(request),
         :ok <- integer_sats(request),
         :ok <- destination(request) do
      payment_hash = Canonical.sha256(@hash_domain <> key)

      {:ok,
       %{
         payment_hash: payment_hash,
         preimage_digest: Canonical.sha256(@preimage_domain <> key),
         fee_sats: 0,
         paid_at: DateTime.utc_now(),
         gateway_ref: gateway_ref_prefix() <> binary_part(payment_hash, 0, 32)
       }}
    end
  end

  defp settle(_request), do: {:error, "simulated_request_invalid"}

  defp idempotency_key(request) do
    case Map.get(request, :idempotency_key) do
      key when is_binary(key) and byte_size(key) >= 8 -> {:ok, key}
      _missing -> {:error, "simulated_idempotency_key_invalid"}
    end
  end

  # Sats are integers. A rail that accepted a float would let one reach a
  # receipt, so this refuses rather than rounds.
  defp integer_sats(request) do
    case Map.get(request, :amount_sats) do
      amount when is_integer(amount) and amount > 0 -> :ok
      _invalid -> {:error, "simulated_amount_sats_not_a_positive_integer"}
    end
  end

  defp destination(request) do
    case Map.get(request, :destination) do
      value when is_binary(value) and value != "" -> :ok
      _missing -> {:error, "simulated_destination_missing"}
    end
  end
end
