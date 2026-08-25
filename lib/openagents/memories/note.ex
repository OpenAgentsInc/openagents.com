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

  defp line(%Memory{} = memory) do
    "[From memory: #{memory.bucket}, #{age(memory)}] #{memory.body}"
  end

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
