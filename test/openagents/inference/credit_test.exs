defmodule OpenAgents.Inference.CreditTest do
  @moduledoc """
  The account's inference money.

  Two facts are proven here because both were false before: that signing in
  raises the allowance, and that what a thread spends comes out of the
  account's credit rather than out of a per-thread figure nothing adds up.
  """

  use OpenAgents.DataCase, async: false

  import Ecto.Query
  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.DataRights
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Repo
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

  # The allowance moved off the config constant and onto the account, so that
  # "a new account is granted $20" could stop meaning "every account is now
  # capped at $20". These three tests are what that distinction rests on.
  describe "the allowance is the account's own" do
    test "a new account is created holding the configured new-account grant" do
      user = github_user("credit-new-account")

      assert user.credit_allowance_microusd == Credit.new_account_allowance()

      assert Credit.allowance(Conversations.ensure_owner_visitor(user).id) ==
               Credit.new_account_allowance()
    end

    test "an account holding more than the current grant keeps it" do
      user = github_user("credit-grandfathered")
      owner = Conversations.ensure_owner_visitor(user)

      # What an account created before the grant was lowered looks like. The
      # migration writes exactly this figure across every row that already
      # existed; here it is set directly so the read is what is under test.
      {1, nil} =
        Repo.update_all(
          from(u in User, where: u.id == ^user.id),
          set: [credit_allowance_microusd: 100_000_000]
        )

      assert Credit.allowance(owner.id) == 100_000_000
      refute Credit.allowance(owner.id) == Credit.new_account_allowance()
      assert Credit.remaining(owner.id) == 100_000_000
    end

    test "signing in again does not re-grant the credit" do
      user = github_user("credit-returning")
      owner = Conversations.ensure_owner_visitor(user)

      {1, nil} =
        Repo.update_all(
          from(u in User, where: u.id == ^user.id),
          set: [credit_allowance_microusd: 3_000_000]
        )

      # `github_user/1` is the upsert the OAuth callback runs, so this is a
      # second sign-in by the same GitHub identity. It must not hand the
      # account the new-account figure again.
      same_user = github_user("credit-returning")

      assert same_user.id == user.id
      assert same_user.credit_allowance_microusd == 3_000_000
      assert Credit.allowance(owner.id) == 3_000_000
    end
  end

  # One GitHub identity holds one credited account: `users.github_id` carries a
  # unique index, so a second signup on the same identity is the same row. The
  # hole that leaves is deletion — `DataRights.delete/3` erases the visitor root
  # the account's grants hang off, and spend is summed from those grants. The
  # user row survives (DATA-004), so the allowance survives with it; without
  # this, everything the account had spent would come back.
  describe "deleting product data does not refund spend" do
    test "the allowance absorbs what the erased grants had metered" do
      user = github_user("credit-deletion")
      owner = Conversations.ensure_owner_visitor(user)

      {:ok, _metered} =
        Inference.record_usage(minted(owner.id), %{
          "output_tokens" => output_tokens_costing(4_000_000)
        })

      granted = Credit.allowance(owner.id)
      assert Credit.spent(owner.id) == 4_000_000
      left = Credit.remaining(owner.id)
      assert left == granted - 4_000_000

      {:ok, conversation} = Conversations.ensure_conversation(user)
      conversation_owner = Conversations.get_conversation_owner!(conversation)
      assert {:ok, :deleted} = DataRights.delete(user, conversation_owner, conversation)

      # A fresh visitor root, so the erased grants are gone and `spent/1` reads
      # zero again. What is left has to be the same number it was.
      next = Conversations.ensure_owner_visitor(Repo.get!(User, user.id))
      refute next.id == conversation_owner.id

      assert Credit.spent(next.id) == 0
      assert Credit.allowance(next.id) == granted - 4_000_000
      assert Credit.remaining(next.id) == left
    end

    test "an account that spent nothing keeps its whole allowance" do
      user = github_user("credit-deletion-unspent")
      granted = Credit.allowance(Conversations.ensure_owner_visitor(user).id)

      {:ok, conversation} = Conversations.ensure_conversation(user)
      conversation_owner = Conversations.get_conversation_owner!(conversation)
      assert {:ok, :deleted} = DataRights.delete(user, conversation_owner, conversation)

      next = Conversations.ensure_owner_visitor(Repo.get!(User, user.id))
      assert Credit.allowance(next.id) == granted
    end
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
