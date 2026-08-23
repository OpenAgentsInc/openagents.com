defmodule OpenAgents.Stacks.MergeQueue do
  @moduledoc """
  The stack contract for merge queues (docs/stacked-prs.md section 14).

  No merge queue exists on the forge yet; this module defines the contract
  any queue implementation must satisfy for stacked pull requests, so the
  behavior stays fixed before an implementation lands:

  - A selected stack prefix enters the queue as one logical item
    (`OpenAgents.Stacks.QueueItem`) with ordered members, expected heads,
    the queue base OID, the stack version, and the policy version.
  - Speculation applies the current queue base, then each member bottom
    to top — never another order.
  - The queue may reorder independent items freely, but it must never
    reorder members within one item.
  - Ejecting a member ejects every selected member above it in the same
    speculative group: their prerequisite is no longer present.
  - A speculative result invalidates when the queue base SHA, the stack
    version, any selected head SHA, or the policy version changes.
  """

  alias OpenAgents.Stacks.QueueItem
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry

  @doc """
  Build one logical queue item from a selected contiguous prefix of a
  stack's active entries.

  `entries` must be the active entries selected for the merge, bottom
  first; the selection must be a contiguous prefix starting at position 1,
  matching the merge contract. `queue_base_oid` is the base the queue will
  speculate onto, and `policy_version` is an opaque identity of the policy
  configuration in force (for example the workflow definition blob OID).
  """
  def item(%Stack{} = stack, entries, queue_base_oid, policy_version)
      when is_list(entries) and entries != [] and is_binary(queue_base_oid) do
    with :ok <- check_prefix(entries) do
      {:ok,
       %QueueItem{
         stack_id: stack.id,
         stack_number: stack.number,
         stack_version: stack.version,
         queue_base_oid: queue_base_oid,
         policy_version: policy_version,
         members:
           Enum.map(entries, fn %StackEntry{} = entry ->
             %{
               position: entry.position,
               pull_request_id: entry.pull_request_id,
               expected_head_oid: entry.observed_head_oid
             }
           end)
       }}
    end
  end

  @doc """
  The ordered application plan for one item's speculative merge group:
  the current queue base, then every member head bottom to top.
  """
  def application_plan(%QueueItem{} = item) do
    [item.queue_base_oid | Enum.map(item.members, & &1.expected_head_oid)]
  end

  @doc """
  Whether a proposed global member order is a legal reordering of the
  given items.

  The queue may interleave and reorder independent items however it wants,
  but the members of one item must keep their relative order. `proposed`
  is the full flattened order as `{stack_id, position}` pairs; it must
  contain exactly the members of `items`.
  """
  def valid_order?(items, proposed) when is_list(items) and is_list(proposed) do
    expected =
      items
      |> Enum.flat_map(fn item ->
        Enum.map(item.members, &{item.stack_id, &1.position})
      end)
      |> Enum.sort()

    same_members = Enum.sort(proposed) == expected

    ordered_within_each_item =
      proposed
      |> Enum.group_by(fn {stack_id, _position} -> stack_id end)
      |> Enum.all?(fn {_stack_id, members} ->
        positions = Enum.map(members, fn {_stack_id, position} -> position end)
        positions == Enum.sort(positions)
      end)

    same_members and ordered_within_each_item
  end

  @doc """
  Eject the member at `position` from the item's speculative group.

  The ejected member's prerequisite chain breaks for everything selected
  above it, so every higher member leaves the group with it. Returns
  `{:ok, %{ejected: members, remaining: members}}` with both halves in
  order, or `{:error, :not_a_member}` when the position is not selected.
  """
  def eject(%QueueItem{} = item, position) when is_integer(position) do
    if Enum.any?(item.members, &(&1.position == position)) do
      {remaining, ejected} = Enum.split_while(item.members, &(&1.position < position))
      {:ok, %{ejected: ejected, remaining: remaining}}
    else
      {:error, :not_a_member}
    end
  end

  @doc """
  Every reason the item's speculative result is no longer valid against
  the observed current state.

  `observed` carries `queue_base_oid`, `stack_version`, `policy_version`,
  and `head_oids` (a map of position to current head OID). An empty list
  means the speculation is still keyed to reality; any entry —
  `:queue_base_changed`, `:stack_version_changed`, `:policy_changed`, or
  `{:head_changed, position}` — invalidates it.
  """
  def invalidations(%QueueItem{} = item, observed) when is_map(observed) do
    base =
      if Map.fetch!(observed, :queue_base_oid) == item.queue_base_oid,
        do: [],
        else: [:queue_base_changed]

    version =
      if Map.fetch!(observed, :stack_version) == item.stack_version,
        do: [],
        else: [:stack_version_changed]

    policy =
      if Map.fetch!(observed, :policy_version) == item.policy_version,
        do: [],
        else: [:policy_changed]

    head_oids = Map.fetch!(observed, :head_oids)

    heads =
      item.members
      |> Enum.filter(&(Map.get(head_oids, &1.position) != &1.expected_head_oid))
      |> Enum.map(&{:head_changed, &1.position})

    base ++ version ++ policy ++ heads
  end

  @doc "Whether the item's speculative result is still valid."
  def valid?(%QueueItem{} = item, observed), do: invalidations(item, observed) == []

  defp check_prefix(entries) do
    positions = Enum.map(entries, & &1.position)

    if positions == Enum.to_list(1..length(entries)) do
      :ok
    else
      {:error, :not_a_prefix}
    end
  end
end
