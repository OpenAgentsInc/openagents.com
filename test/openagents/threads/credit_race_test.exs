defmodule OpenAgents.Threads.CreditRaceTest do
  @moduledoc """
  What two simultaneous thread opens can take from one account (issue #195).

  The admission count and the mint's remainder read are serialized on the
  owner visitor row, so concurrent opens produce exactly what the same opens
  produce in sequence: at the cap's boundary one thread is admitted, against
  an exhausted account both opens are refused and leave nothing behind, and
  each mint reads the metered remainder at its own turn.

  What is deliberately not asserted is that overlapping live ceilings sum to
  the remainder. A live grant's unspent headroom does not reserve credit,
  because a delegated child thread must be mintable while its parent holds the
  whole remaining balance as its ceiling — reserving headroom would refuse
  every such child with `:credit_exhausted`. The joint exposure is instead
  bounded by the admission cap, which is why the cap has to hold under
  concurrency (THREAD-001).
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Threads

  test "simultaneous opens at the admission boundary admit exactly one thread" do
    cap(2)
    visitor = visitor("cap-race")

    {:ok, _first} = Threads.open(%Visitor{id: visitor}, "Already open")

    results =
      ["Second", "Third"]
      |> Task.async_stream(
        fn objective -> Threads.open(%Visitor{id: visitor}, objective) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _thread}, &1)) == 1
    assert Enum.count(results, &match?({:error, :thread_quota_reached}, &1)) == 1
    assert Threads.open_count(visitor) == 2
  end

  test "simultaneous opens against an exhausted account jointly mint nothing" do
    visitor = visitor("exhausted-race")

    {:ok, _spent} =
      Inference.record_usage(minted(visitor), %{
        "output_tokens" => output_tokens_costing(Credit.allowance(visitor))
      })

    assert Credit.remaining(visitor) == 0

    results =
      ["First racer", "Second racer"]
      |> Task.async_stream(
        fn objective -> Threads.open_and_mint(%Visitor{id: visitor}, objective) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:error, :credit_exhausted}, &1))

    # A refused open cancels the thread it admitted and mints no authority.
    # The racers leave the account exactly one grant — the exhausted one that
    # spent the credit — and no open thread: exhausting the grant abandoned
    # its thread, and admission reaped it.
    assert Threads.open_count(visitor) == 0
    assert Repo.aggregate(from(g in Grant, where: g.owner_visitor_id == ^visitor), :count) == 1
  end

  test "simultaneous opens mint the serialized remainder, the figure sequential opens mint" do
    visitor = visitor("remainder-race")
    spent = 250_000

    {:ok, _spent} =
      Inference.record_usage(minted(visitor), %{"output_tokens" => output_tokens_costing(spent)})

    remainder = Credit.allowance(visitor) - spent
    assert Credit.remaining(visitor) == remainder

    grants =
      ["First racer", "Second racer"]
      |> Task.async_stream(
        fn objective -> Threads.open_and_mint(%Visitor{id: visitor}, objective) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, _thread, grant, _token}} -> grant end)

    # Each racer is ceiled at the metered remainder — the same ceiling the two
    # opens mint in either serial order, because a mint spends nothing and a
    # live grant's headroom reserves nothing. Concurrency adds no exposure the
    # serial schedule does not already have; what bounds the sum of live
    # ceilings is the admission cap (THREAD-001, issue #195).
    assert Enum.map(grants, & &1.max_cost_microusd) == [remainder, remainder]
  end

  test "serial behavior is unchanged: the next thread is ceiled at what spend left behind" do
    visitor = visitor("serial")
    spent = 250_000

    {:ok, first} = Threads.open(%Visitor{id: visitor}, "Spend a little")
    {:ok, first, grant, _token} = Threads.mint_grant(first)

    assert grant.max_cost_microusd == Credit.allowance(visitor)

    {:ok, _spent} =
      Inference.record_usage(grant, %{"output_tokens" => output_tokens_costing(spent)})

    {:ok, _finished} = Threads.finish(first, %{report: "Done."})

    {:ok, second} = Threads.open(%Visitor{id: visitor}, "Spend the rest")
    {:ok, _second, next_grant, _token} = Threads.mint_grant(second)

    assert next_grant.max_cost_microusd == Credit.allowance(visitor) - spent
  end

  defp visitor(key) do
    {:ok, conversation} = Conversations.ensure_conversation("credit-race-#{key}")
    conversation.visitor_id
  end

  # A grant names exactly one fence, so spend is recorded through a real
  # thread's grant rather than a fenceless one the changeset would refuse.
  defp minted(visitor_id) do
    {:ok, thread} = Threads.open(%Visitor{id: visitor_id}, "Spend some credit")
    {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
    grant
  end

  # Cost is priced from tokens by `OpenAgents.Inference`, never taken from a
  # caller, so spend is stated here in the output tokens that price to it.
  defp output_tokens_costing(microusd) do
    div(
      microusd * 1_000,
      Application.fetch_env!(:openagents, :inference_output_price_microusd_per_ktoken)
    )
  end

  defp cap(limit) do
    previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
    Application.put_env(:openagents, :maximum_open_threads_per_account, limit)

    on_exit(fn ->
      Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
    end)
  end
end
