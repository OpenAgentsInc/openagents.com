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

    # The account's credit is the only ceiling a thread gets. The configured
    # per-thread cost cap was $2 and is now unset, so the cost ceiling is not a
    # cap being raised to the remainder — it is the remainder, and nothing else
    # bounds the thread.
    assert is_nil(Threads.ceilings().max_cost_microusd)
    assert is_nil(remaining.max_calls)
    assert is_nil(remaining.max_total_tokens)
    assert is_nil(remaining.ttl_seconds)
  end

  test "an account with nothing left is refused rather than minted a grant" do
    visitor_id = visitor("exhausted")

    {:ok, _metered} =
      Inference.record_usage(minted(visitor_id), %{
        "output_tokens" => output_tokens_costing(Credit.allowance(visitor_id))
      })

    assert Threads.ceilings(visitor_id) == {:error, :credit_exhausted}
  end

  # METER-001. A cost ceiling can only stop spend it can measure, so a lane
  # with no declared rates draws nothing down. That is a consequence of not
  # knowing the rates, and the account's read has to say so rather than report
  # a balance that looks untouched.
  describe "spend the deployment has no price for" do
    test "an unpriced call draws nothing down, and the balance says so" do
      owner = account("credit-unpriced")
      luna = Application.fetch_env!(:openagents, :openai_model)

      {:ok, thread} = Threads.open(%Visitor{id: owner.id}, "Run the unpriced lane", model: luna)
      {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
      {:ok, _metered} = Inference.record_usage(grant, %{"output_tokens" => 500_000})

      # `spent/1` is a floor, not a total, and the floor here is zero.
      assert Credit.spent(owner.id) == 0
      assert Credit.remaining(owner.id) == Credit.allowance(owner.id)

      # What stops that reading as "this account has spent nothing".
      assert Credit.unpriced_calls(owner.id) == 1

      balance = Credit.balance(owner.id)
      assert balance.spent_microusd == 0
      assert balance.unpriced_calls == 1
      refute balance.complete?
    end

    test "an account whose every call was priced reports a complete balance" do
      owner = account("credit-complete")

      {:ok, _metered} =
        Inference.record_usage(minted(owner.id), %{
          "output_tokens" => output_tokens_costing(100_000)
        })

      balance = Credit.balance(owner.id)

      assert balance.spent_microusd == 100_000
      assert balance.unpriced_calls == 0
      assert balance.complete?
    end

    test "a grant that never bought anything is not counted as unpriced spend" do
      owner = account("credit-idle")
      luna = Application.fetch_env!(:openagents, :openai_model)

      {:ok, thread} = Threads.open(%Visitor{id: owner.id}, "Mint and stop", model: luna)
      {:ok, _fenced, _grant, _token} = Threads.mint_grant(thread)

      assert Credit.unpriced_calls(owner.id) == 0
      assert Credit.balance(owner.id).complete?
    end
  end
end
