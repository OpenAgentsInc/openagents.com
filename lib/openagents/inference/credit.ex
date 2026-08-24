defmodule OpenAgents.Inference.Credit do
  @moduledoc """
  The inference money an account holds, and what it has spent.

  A grant carries a cost ceiling, so before this module a thread's budget was
  the same small figure every time and nothing added those figures up: an
  account could open thread after thread, each with its own ceiling, and no
  question anywhere was "how much has this account spent". That is the wrong
  shape for both readers of the product. A signed-in account was given no more
  than an anonymous one, and an anonymous one was given an unbounded number of
  bounded threads.

  So the credit is the account's, and a thread draws against it. Signing in is
  what buys the difference: `account_credit_microusd` for an account with a
  user behind it, `visitor_credit_microusd` for a browser that has not signed
  in. `remaining/1` is the allowance minus everything the account's grants have
  metered, and a thread is minted for exactly that, so one thread may spend the
  whole balance and the next is refused rather than handed a fresh ceiling.

  Spend is read from the grants themselves rather than kept in a second
  counter. `OpenAgents.Inference.record_usage/2` is the one writer of
  `usage`, the proxy calls it for every call it buys, and a revoked or expired
  grant keeps what it metered — so summing that column is the same number a
  ledger would hold, without a ledger that can disagree with it.
  """

  import Ecto.Query

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Repo

  @doc """
  What this account may spend in total, in microUSD.

  Signing in raises it, which is the whole point: an account with a user behind
  it holds `account_credit_microusd`, and a visitor that has only a browser key
  holds `visitor_credit_microusd`.
  """
  @spec allowance(String.t()) :: non_neg_integer()
  def allowance(visitor_id) when is_binary(visitor_id) do
    if signed_in?(visitor_id), do: account_allowance(), else: visitor_allowance()
  end

  @doc "What a signed-in account may spend in total, in microUSD."
  @spec account_allowance() :: non_neg_integer()
  def account_allowance, do: setting(:account_credit_microusd, 100_000_000)

  @doc "What a browser that has not signed in may spend in total, in microUSD."
  @spec visitor_allowance() :: non_neg_integer()
  def visitor_allowance, do: setting(:visitor_credit_microusd, 2_000_000)

  @doc "What every grant this account has held has metered, in microUSD."
  @spec spent(String.t()) :: non_neg_integer()
  def spent(visitor_id) when is_binary(visitor_id) do
    Repo.one(
      from grant in Grant,
        where: grant.owner_visitor_id == ^visitor_id,
        select:
          type(
            coalesce(
              sum(
                fragment("COALESCE((? ->> 'estimated_cost_microusd')::bigint, 0)", grant.usage)
              ),
              0
            ),
            :integer
          )
    )
  end

  @doc "What is left of this account's credit, in microUSD. Never negative."
  @spec remaining(String.t()) :: non_neg_integer()
  def remaining(visitor_id) when is_binary(visitor_id) do
    max(allowance(visitor_id) - spent(visitor_id), 0)
  end

  defp signed_in?(visitor_id) do
    Repo.exists?(from v in Visitor, where: v.id == ^visitor_id and not is_nil(v.user_id))
  end

  defp setting(key, default), do: Application.get_env(:openagents, key, default)
end
