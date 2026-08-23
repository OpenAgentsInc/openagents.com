defmodule OpenAgents.Forum.Tips.PaymentService do
  @moduledoc """
  The boundary between the forum and the wallet software that moves sats.

  The forum hands a request to an admitted payment service and stores what came
  back. It never holds funds, so a service that is missing or unreachable can
  only stop new tips from settling; totals, receipts, and ranking keep working
  from what already settled.
  """

  @type request :: %{
          kind: String.t(),
          destination: String.t(),
          amount_sats: pos_integer(),
          idempotency_key: String.t()
        }

  @type settlement :: %{
          payment_hash: String.t(),
          fee_sats: non_neg_integer(),
          settled_at: DateTime.t()
        }

  @doc """
  Pays one request.

  The same `idempotency_key` must never move sats twice: an admitted service
  either replays its first settlement or refuses the second call.
  """
  @callback pay(request()) ::
              {:ok, settlement()}
              | {:error, :payment_service_unavailable}
              | {:error, {:payment_failed, String.t()}}

  @doc "The admitted service for this runtime."
  @spec adapter() :: module()
  def adapter do
    Keyword.get(
      Application.get_env(:openagents, :forum_tips, []),
      :adapter,
      OpenAgents.Forum.Tips.PaymentService.Unavailable
    )
  end

  @doc "Whether the forum advertises tipping at all."
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(Application.get_env(:openagents, :forum_tips, []), :enabled, false) == true
  end

  @spec pay(request()) ::
          {:ok, settlement()}
          | {:error, :payment_service_unavailable}
          | {:error, {:payment_failed, String.t()}}
  def pay(request), do: adapter().pay(request)
end
