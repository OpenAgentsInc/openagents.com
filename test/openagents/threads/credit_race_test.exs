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
  because a delegated child thread must be mintable while its parent holds
  the whole remaining balance as its ceiling — reserving headroom would refuse
  every such child with `:credit_exhausted`. The joint exposure is instead
  bounded by the admission cap, which is why the cap has to hold under
  concurrency (THREAD-001).

  These tests do not use the SQL sandbox. Each concurrent worker checks out a
  real database connection, so the `FOR UPDATE` locks are exercised against
  PostgreSQL and not flattened by a single shared sandbox connection.
  """

  use ExUnit.Case, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Inference.Models
  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Thread

  import Ecto.Query

  test "simultaneous opens at the admission boundary admit exactly one thread" do
    cap(2)
    visitor_id = fresh_visitor("cap-race")

    unboxed(fn ->
      {:ok, _first} = Threads.open(%Visitor{id: visitor_id}, "Already open")
    end)

    results =
      concurrent(["Second", "Third"], fn objective ->
        Threads.open(%Visitor{id: visitor_id}, objective)
      end)

    assert Enum.count(results, &match?({:ok, _thread}, &1)) == 1
    assert Enum.count(results, &match?({:error, :thread_quota_reached}, &1)) == 1
    assert unboxed(fn -> Threads.open_count(visitor_id) end) == 2
  end

  test "simultaneous opens against an exhausted account jointly mint nothing" do
    visitor_id = fresh_visitor("exhausted-race")

    unboxed(fn ->
      {:ok, _spent} =
        Inference.record_usage(minted(visitor_id), %{
          "output_tokens" => output_tokens_costing(Credit.allowance(visitor_id))
        })
    end)

    assert unboxed(fn -> Credit.remaining(visitor_id) end) == 0

    results =
      concurrent(["First racer", "Second racer"], fn objective ->
        Threads.open_and_mint(%Visitor{id: visitor_id}, objective)
      end)

    assert Enum.all?(results, &match?({:error, :credit_exhausted}, &1))

    # A refused open cancels the thread it admitted and mints no authority.
    # The racers leave the account exactly one grant — the exhausted one that
    # spent the credit — and no open thread: exhausting the grant abandoned
    # its thread, and admission reaped it.
    assert unboxed(fn -> Threads.open_count(visitor_id) end) == 0

    assert unboxed(fn ->
             Repo.aggregate(from(g in Grant, where: g.owner_visitor_id == ^visitor_id), :count)
           end) == 1
  end

  test "simultaneous opens mint the serialized remainder, the figure sequential opens mint" do
    visitor_id = fresh_visitor("remainder-race")
    spent = 250_000

    unboxed(fn ->
      {:ok, _spent} =
        Inference.record_usage(minted(visitor_id), %{
          "output_tokens" => output_tokens_costing(spent)
        })
    end)

    remainder = unboxed(fn -> Credit.allowance(visitor_id) - spent end)
    assert unboxed(fn -> Credit.remaining(visitor_id) end) == remainder

    grants =
      concurrent(["First racer", "Second racer"], fn objective ->
        case Threads.open_and_mint(%Visitor{id: visitor_id}, objective) do
          {:ok, _thread, grant, _token} -> grant
          other -> other
        end
      end)

    # Each racer is ceiled at the metered remainder — the same ceiling the two
    # opens mint in either serial order, because a mint spends nothing and a
    # live grant's headroom reserves nothing. Concurrency adds no exposure the
    # serial schedule does not already have; what bounds the sum of live
    # ceilings is the admission cap (THREAD-001, issue #195).
    assert Enum.map(grants, & &1.max_cost_microusd) == [remainder, remainder]
  end

  test "serial behavior is unchanged: the next thread is ceiled at what spend left behind" do
    visitor_id = fresh_visitor("serial")
    spent = 250_000

    unboxed(fn ->
      {:ok, first} = Threads.open(%Visitor{id: visitor_id}, "Spend a little")
      {:ok, first, grant, _token} = Threads.mint_grant(first)
      assert grant.max_cost_microusd == Credit.allowance(visitor_id)

      {:ok, _spent} =
        Inference.record_usage(grant, %{
          "output_tokens" => output_tokens_costing(spent)
        })

      {:ok, _finished} = Threads.finish(first, %{report: "Done."})
      {:ok, second} = Threads.open(%Visitor{id: visitor_id}, "Spend the rest")
      {:ok, _second, next_grant, _token} = Threads.mint_grant(second)
      assert next_grant.max_cost_microusd == Credit.allowance(visitor_id) - spent
      :ok
    end)
  end

  test "concurrent appends on one thread count every event" do
    visitor_id = fresh_visitor("event-race")

    thread =
      unboxed(fn ->
        {:ok, thread} = Threads.open(%Visitor{id: visitor_id}, "Event race")
        thread
      end)

    results =
      concurrent([%{"i" => "a"}, %{"i" => "b"}], fn payload ->
        Threads.record_event(thread, "thread.race", payload)
      end)

    assert Enum.all?(results, &match?({:ok, _thread}, &1))

    {event_count, events} =
      unboxed(fn ->
        current = Repo.get!(Thread, thread.id)
        {current.event_count, Threads.list_events(current)}
      end)

    assert event_count == 3
    assert length(events) == 3
  end

  defp fresh_visitor(key) do
    visitor_id = unboxed(fn -> visitor(key) end)
    on_exit(fn -> unboxed(fn -> cleanup(visitor_id) end) end)
    visitor_id
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
    div(microusd * 1_000_000, Models.default().pricing.output_per_million_tokens)
  end

  defp cap(limit) do
    previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
    Application.put_env(:openagents, :maximum_open_threads_per_account, limit)

    on_exit(fn ->
      Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
    end)
  end

  defp concurrent(inputs, fun) do
    inputs
    |> Task.async_stream(
      fn item -> unboxed(fn -> fun.(item) end) end,
      max_concurrency: 2,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp unboxed(fun) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
  end

  defp cleanup(visitor_id) do
    Repo.delete_all(from(v in Visitor, where: v.id == ^visitor_id))
  end
end
