defmodule OpenAgents.Stacks.QueueItem do
  @moduledoc """
  One logical merge-queue item for a selected stack prefix
  (docs/stacked-prs.md section 14).

  The queue treats the whole prefix as one item with ordered internal
  members. Each member records the position, pull request, and expected
  head OID it was selected with; the item records the queue base OID the
  speculation applies onto, the stack version, and the policy version, so
  a speculative result stays keyed to everything that produced it.
  """

  @enforce_keys [:stack_id, :stack_number, :stack_version, :queue_base_oid, :members]
  defstruct [
    :stack_id,
    :stack_number,
    :stack_version,
    :queue_base_oid,
    :policy_version,
    :members
  ]
end
