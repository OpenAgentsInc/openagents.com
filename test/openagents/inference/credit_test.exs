defmodule OpenAgents.Inference.CreditTest do
  @moduledoc """
  The account's inference money.

  Two facts are proven here because both were false before: that signing in
  raises the allowance, and that what a thread spends comes out of the
  account's credit rather than out of a per-thread figure nothing adds up.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Threads

  defp account(key) do
    key |> github_user() |> Conversations.ensure_owner_visitor()
  end

  defp visitor(key) do
    {:ok, conversation} = Conversations.ensure_conversation("credit-#{key}")
    conversation.visitor_id
  end

  # Cost is priced from tokens by `OpenAgents.Inference`, never taken from a
  # caller, so spend is stated here in the output tokens that price to it.
  defp output_tokens_costing(microusd) do
    div(
      microusd * 1_000,
      Application.fetch_env!(:openagents, :inference_output_price_microusd_per_ktoken)
    )
  end

  # A grant names exactly one fence, so spend is recorded through a real
  # thread's grant rather than a fenceless one the changeset would refuse.
  defp minted(visitor_id) do
    {:ok, thread} = Threads.open(%Visitor{id: visitor_id}, "spend some credit")
    {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
    grant
  end

  test "signing in raises the allowance to the account credit" do
    assert Credit.allowance(account("credit-signed-in").id) ==
             Application.fetch_env!(:openagents, :account_credit_microusd)
  end

  test "a visitor that has not signed in holds the visitor credit" do
    assert Credit.allowance(visitor("anonymous")) ==
             Application.fetch_env!(:openagents, :visitor_credit_microusd)
  end

  test "an account that has spent nothing has its whole allowance left" do
    owner = account("credit-unspent")

    assert Credit.spent(owner.id) == 0
    assert Credit.remaining(owner.id) == Credit.allowance(owner.id)
  end

  test "what a grant metered comes out of the account's remaining credit" do
    owner = account("credit-metered")

    {:ok, _metered} =
      Inference.record_usage(minted(owner.id), %{
        "output_tokens" => output_tokens_costing(250_000)
      })

    assert Credit.spent(owner.id) == 250_000
    assert Credit.remaining(owner.id) == Credit.allowance(owner.id) - 250_000
  end

  test "remaining credit never reads as negative" do
    visitor_id = visitor("overspent")
    allowance = Credit.allowance(visitor_id)

    {:ok, _metered} =
      Inference.record_usage(minted(visitor_id), %{
        "output_tokens" => output_tokens_costing(allowance * 2)
      })

    assert Credit.remaining(visitor_id) == 0
  end

  test "a thread is minted for what the account has left, not a fresh ceiling" do
    owner = account("credit-thread")

    {:ok, remaining} = Threads.ceilings(owner.id)

    assert remaining.max_cost_microusd == Credit.remaining(owner.id)
    assert remaining.max_cost_microusd > Threads.ceilings().max_cost_microusd
  end

  test "an account with nothing left is refused rather than minted a grant" do
    visitor_id = visitor("exhausted")

    {:ok, _metered} =
      Inference.record_usage(minted(visitor_id), %{
        "output_tokens" => output_tokens_costing(Credit.allowance(visitor_id))
      })

    assert Threads.ceilings(visitor_id) == {:error, :credit_exhausted}
  end
end
