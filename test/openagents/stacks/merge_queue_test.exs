defmodule OpenAgents.Stacks.MergeQueueTest do
  @moduledoc """
  The stack merge-queue contract (#54): logical item grouping with expected
  heads and the queue base, bottom-to-top speculation order, reordering
  bounds, cascade ejection, and every invalidation trigger — against a fake
  queue base, since no queue implementation exists on the forge yet.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Stacks.MergeQueue
  alias OpenAgents.Stacks.QueueItem
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry

  @queue_base String.duplicate("a", 40)
  @policy String.duplicate("f", 40)

  describe "item/4" do
    test "groups a selected prefix with expected heads, queue base, and versions" do
      stack = stack(version: 4)
      entries = entries(["1111", "2222", "3333"])

      {:ok, item} = MergeQueue.item(stack, entries, @queue_base, @policy)

      assert item.stack_id == stack.id
      assert item.stack_number == stack.number
      assert item.stack_version == 4
      assert item.queue_base_oid == @queue_base
      assert item.policy_version == @policy

      assert Enum.map(item.members, & &1.position) == [1, 2, 3]

      assert Enum.map(item.members, & &1.expected_head_oid) ==
               Enum.map(entries, & &1.observed_head_oid)

      assert Enum.map(item.members, & &1.pull_request_id) ==
               Enum.map(entries, & &1.pull_request_id)
    end

    test "rejects a selection that is not a contiguous prefix" do
      stack = stack(version: 1)
      [entry_1, _entry_2, entry_3] = entries(["1111", "2222", "3333"])

      assert {:error, :not_a_prefix} =
               MergeQueue.item(stack, [entry_1, entry_3], @queue_base, @policy)

      assert {:error, :not_a_prefix} =
               MergeQueue.item(stack, [entry_3], @queue_base, @policy)
    end
  end

  describe "application_plan/1" do
    test "applies the current queue base, then every member bottom to top" do
      {:ok, item} =
        MergeQueue.item(stack(version: 1), entries(["1111", "2222"]), @queue_base, @policy)

      assert MergeQueue.application_plan(item) == [
               @queue_base,
               oid("1111"),
               oid("2222")
             ]
    end
  end

  describe "valid_order?/2" do
    test "independent items may reorder and interleave" do
      {:ok, item_a} =
        MergeQueue.item(stack(id: "a"), entries(["1111", "2222"]), @queue_base, @policy)

      {:ok, item_b} =
        MergeQueue.item(stack(id: "b"), entries(["3333", "4444"]), @queue_base, @policy)

      assert MergeQueue.valid_order?([item_a, item_b], [
               {"b", 1},
               {"a", 1},
               {"b", 2},
               {"a", 2}
             ])
    end

    test "members of one stack never reorder" do
      {:ok, item_a} =
        MergeQueue.item(stack(id: "a"), entries(["1111", "2222"]), @queue_base, @policy)

      {:ok, item_b} = MergeQueue.item(stack(id: "b"), entries(["3333"]), @queue_base, @policy)

      refute MergeQueue.valid_order?([item_a, item_b], [
               {"a", 2},
               {"b", 1},
               {"a", 1}
             ])
    end

    test "the proposed order must contain exactly the selected members" do
      {:ok, item} =
        MergeQueue.item(stack(id: "a"), entries(["1111", "2222"]), @queue_base, @policy)

      refute MergeQueue.valid_order?([item], [{"a", 1}])
      refute MergeQueue.valid_order?([item], [{"a", 1}, {"a", 2}, {"a", 3}])
    end
  end

  describe "eject/2" do
    test "ejecting a lower member ejects every selected member above it" do
      {:ok, item} =
        MergeQueue.item(
          stack(version: 1),
          entries(["1111", "2222", "3333"]),
          @queue_base,
          @policy
        )

      {:ok, %{ejected: ejected, remaining: remaining}} = MergeQueue.eject(item, 2)

      assert Enum.map(ejected, & &1.position) == [2, 3]
      assert Enum.map(remaining, & &1.position) == [1]
    end

    test "ejecting the bottom member empties the group" do
      {:ok, item} =
        MergeQueue.item(stack(version: 1), entries(["1111", "2222"]), @queue_base, @policy)

      {:ok, %{ejected: ejected, remaining: []}} = MergeQueue.eject(item, 1)
      assert Enum.map(ejected, & &1.position) == [1, 2]
    end

    test "an unselected position is not a member" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      assert {:error, :not_a_member} = MergeQueue.eject(item, 2)
    end
  end

  describe "invalidations/2" do
    test "a matching observation keeps the speculative result valid" do
      {:ok, item} =
        MergeQueue.item(stack(version: 3), entries(["1111", "2222"]), @queue_base, @policy)

      observed = observed(item)

      assert MergeQueue.invalidations(item, observed) == []
      assert MergeQueue.valid?(item, observed)
    end

    test "a queue base advance invalidates" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      observed = %{observed(item) | queue_base_oid: oid("9999")}

      assert MergeQueue.invalidations(item, observed) == [:queue_base_changed]
      refute MergeQueue.valid?(item, observed)
    end

    test "a stack version move invalidates" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      observed = %{observed(item) | stack_version: 2}

      assert MergeQueue.invalidations(item, observed) == [:stack_version_changed]
    end

    test "a policy version change invalidates" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      observed = %{observed(item) | policy_version: oid("8888")}

      assert MergeQueue.invalidations(item, observed) == [:policy_changed]
    end

    test "any selected head move invalidates that member" do
      {:ok, item} =
        MergeQueue.item(stack(version: 1), entries(["1111", "2222"]), @queue_base, @policy)

      observed =
        Map.update!(observed(item), :head_oids, &Map.put(&1, 2, oid("7777")))

      assert MergeQueue.invalidations(item, observed) == [{:head_changed, 2}]
    end

    test "every trigger reports together" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      observed = %{
        queue_base_oid: oid("9999"),
        stack_version: 5,
        policy_version: oid("8888"),
        head_oids: %{1 => oid("7777")}
      }

      assert MergeQueue.invalidations(item, observed) == [
               :queue_base_changed,
               :stack_version_changed,
               :policy_changed,
               {:head_changed, 1}
             ]
    end
  end

  describe "the queue item shape" do
    test "is the documented logical item" do
      {:ok, item} = MergeQueue.item(stack(version: 1), entries(["1111"]), @queue_base, @policy)

      assert %QueueItem{} = item
    end
  end

  ## Fakes

  defp stack(attrs) do
    %Stack{
      id: Keyword.get(attrs, :id, "stack-id"),
      number: 7,
      trunk_ref: "main",
      version: Keyword.get(attrs, :version, 1)
    }
  end

  defp entries(seeds) do
    seeds
    |> Enum.with_index(1)
    |> Enum.map(fn {seed, position} ->
      %StackEntry{
        position: position,
        pull_request_id: "pr-#{position}",
        boundary_oid: oid("0000"),
        observed_head_oid: oid(seed)
      }
    end)
  end

  defp observed(item) do
    %{
      queue_base_oid: item.queue_base_oid,
      stack_version: item.stack_version,
      policy_version: item.policy_version,
      head_oids: Map.new(item.members, &{&1.position, &1.expected_head_oid})
    }
  end

  defp oid(seed), do: String.duplicate(seed, div(40, byte_size(seed)))
end
