defmodule OpenAgents.Memories.Note do
  @moduledoc """
  The `[From memory: …]` block a recalled turn carries.

  The convention is the retrieval rails': the capability catalog and the
  knowledge base each attach what they found as a bracketed note the model
  reads as context rather than as a tool result, and memory reads the same way.
  One line per memory, each labelled with its bucket and its age, because a
  model shown "you use pnpm" without knowing whether the reader said so
  yesterday or eighteen months ago cannot weigh it.

  When the bounds excluded something, the block says so in its last line. A
  note that trailed off would leave the model believing it had been told
  everything the account remembers.

  ## The system bucket reads differently on purpose

  A `user` or `learned` line is labelled with its bucket and its age. A
  `system` line is labelled `(system, as of <date>, admitted)`, because a claim
  the network makes has to be weighed against a claim the reader made, and the
  three things that decide that weight are which bucket it came from, what date
  it was observed true, and whether a steward admitted it. The date is the
  row's `as_of` rather than its age, since `as_of` dates the claim while the
  insert time only orders the chain, and a stale truth should read as dated.

  The status is the one the admission records derived
  (`OpenAgents.Memories.Admissions`), carried on `derived_status`. It is never
  the `admission` column, which is the author's own claim about their own row.

  Specification section 7.1 draws the example with the body inside the
  brackets. This repository's rails put the body after them, and one note
  carrying two bracket shapes would be harder to read than either, so the label
  is the specification's verbatim and the placement is the rails'.
  """

  alias OpenAgents.Memories.{Memory, Recall}
  alias OpenAgentsWeb.RelativeTime

  @doc """
  Renders one recall as a note, or `nil` when there is nothing to say.

  An empty recall renders `nil` rather than an empty block, so a turn with no
  memories behind it is exactly the turn it was before recall existed.
  """
  @spec render(Recall.t()) :: String.t() | nil
  def render(%Recall{memories: []}), do: nil

  def render(%Recall{memories: memories, dropped: dropped}) do
    (Enum.map(memories, &line/1) ++ omission(dropped))
    |> Enum.join("\n")
  end

  defp line(%Memory{bucket: "system"} = memory) do
    "[From memory: (system, as of #{as_of(memory)}, #{status(memory)})] #{memory.body}"
  end

  defp line(%Memory{} = memory) do
    "[From memory: #{memory.bucket}, #{age(memory)}] #{memory.body}"
  end

  defp as_of(%Memory{as_of: %Date{} = date}), do: Date.to_iso8601(date)
  defp as_of(_undated), do: "date unknown"

  # Derived, never claimed. A row that reached a note without a derived status
  # is a bug in the eligibility filter rather than a candidate to describe as
  # one, so it says what it knows and nothing more.
  defp status(%Memory{derived_status: derived}) when is_binary(derived), do: derived
  defp status(_underived), do: "status unknown"

  defp omission(0), do: []

  defp omission(dropped) do
    [
      "[From memory: #{dropped} more #{noun(dropped)} not attached; " <>
        "this turn's recall is bounded to #{OpenAgents.Memories.maximum_attached()} entries " <>
        "and #{OpenAgents.Memories.maximum_attached_characters()} characters.]"
    ]
  end

  defp noun(1), do: "memory was"
  defp noun(_many), do: "memories were"

  defp age(%Memory{inserted_at: at}) do
    case RelativeTime.ago(at) do
      nil -> "age unknown"
      ago -> ago
    end
  end
end
