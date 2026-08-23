defmodule OpenAgents.Chat.TokenUsage do
  @moduledoc """
  The one decision about which token counts a set of chat turns reports.

  The chat console shows token counts twice: once per turn, and once for the
  whole conversation. Both read this module, and a turn's line is the report
  over a list of one turn, so the running list cannot claim a measurement the
  turns it describes disclaim.

  A count is provider-reported evidence or it is absent. Nothing here derives a
  count from another count, and a reported zero stays distinguishable from a
  count the provider never sent.
  """

  @kinds [input: "Input", output: "Output", reasoning: "Reasoning", cached: "Cached"]

  @type count :: non_neg_integer() | nil
  @type usage :: %{
          optional(:input) => count(),
          optional(:output) => count(),
          optional(:reasoning) => count(),
          optional(:cached) => count(),
          optional(:total) => count()
        }

  @doc "The token kinds the console reports, in display order."
  @spec kinds() :: keyword(String.t())
  def kinds, do: @kinds

  @doc """
  The counts a set of turns reports, as `{kind, label, count}` in display order.

  A turn that left a kind unreported leaves the set's knowledge of that kind
  incomplete. An incomplete sum above zero still carries the measurement the
  reporting turns produced. An incomplete sum of zero measures nothing, so the
  kind stays off the report exactly as a wholly unreported kind does: a set
  whose reasoning turns report no count must not read as a set that reasoned
  none.
  """
  @spec counts([usage()]) :: [{atom(), String.t(), non_neg_integer()}]
  def counts(usages) do
    usages = Enum.filter(usages, &is_map/1)

    for {kind, label} <- @kinds, count = reported_count(usages, kind), do: {kind, label, count}
  end

  @doc """
  The token total for a set of turns, and where the number came from.

  `:reported` means every turn carried a provider total. `:derived` means at
  least one turn did not, and its share of the number is its input plus its
  output, which is a fallback rather than a count the provider sent.
  """
  @spec total([usage()]) :: {non_neg_integer(), :reported | :derived} | nil
  def total(usages) do
    case Enum.filter(usages, &is_map/1) do
      [] ->
        nil

      usages ->
        provenance =
          if Enum.all?(usages, &is_integer(Map.get(&1, :total))), do: :reported, else: :derived

        {Enum.sum(Enum.map(usages, &turn_total/1)), provenance}
    end
  end

  defp reported_count(usages, kind) do
    counts = Enum.map(usages, &Map.get(&1, kind))
    reported = Enum.reject(counts, &is_nil/1)
    sum = Enum.sum(reported)

    cond do
      reported == [] -> nil
      sum > 0 -> sum
      length(reported) == length(counts) -> 0
      true -> nil
    end
  end

  defp turn_total(%{total: total}) when is_integer(total), do: total
  defp turn_total(usage), do: (Map.get(usage, :input) || 0) + (Map.get(usage, :output) || 0)
end
