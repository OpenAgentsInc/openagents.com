defmodule OpenAgentsWeb.RelativeTime do
  @moduledoc """
  How long ago something happened, in one place.

  Every recency surface in the product answers the same question — issue rows,
  the workspace feed, a repository's latest commit — and until this module
  existed each one answered it in its own words. A repository home said
  `2026-08-22` for a commit pushed minutes earlier while the issue list beside
  it said `4m ago`, so the forge spoke two time dialects on two adjacent pages.

  The scale is deliberately coarse: minutes for the first hour, hours for the
  first day, days after that. A reader scanning a list wants to know whether
  something is fresh, not how fresh to the second, and a coarse scale keeps the
  column narrow enough to sit at a row's trailing edge.

  Precision is never lost, only moved. `exact/1` renders the same moment in
  full for a `title` tooltip, and every call site pairs the relative text with
  the machine-readable stamp in a `<time datetime=...>` attribute.
  """

  @doc """
  How long ago, coarsely: minutes, then hours, then days.

  Takes a `DateTime`, a `NaiveDateTime` read as UTC, or an ISO 8601 string as
  Git writes it. Returns `nil` for anything it cannot read, so a call site can
  render the stamp only when there is one.
  """
  def since(at) do
    case to_datetime(at) do
      nil ->
        nil

      at ->
        case DateTime.diff(DateTime.utc_now(), at, :second) do
          s when s < 3_600 -> "#{max(div(s, 60), 1)}m"
          s when s < 86_400 -> "#{div(s, 3_600)}h"
          s -> "#{div(s, 86_400)}d"
        end
    end
  end

  @doc "The same span with the word a reader expects after it: `4m ago`."
  def ago(at) do
    case since(at) do
      nil -> nil
      span -> "#{span} ago"
    end
  end

  @doc "The exact moment, for the `title` a coarse stamp hides it behind."
  def exact(at) do
    case to_datetime(at) do
      nil -> nil
      at -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    end
  end

  @doc "The same moment as a machine-readable `datetime` attribute."
  def machine(at) do
    case to_datetime(at) do
      nil -> nil
      at -> DateTime.to_iso8601(at)
    end
  end

  defp to_datetime(nil), do: nil
  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # `%cI` from `OpenAgents.Forge.Browse` is strict ISO 8601, and a commit stamp
  # reaches a template as that string rather than as a struct.
  # `DateTime.from_iso8601/1` hands back the moment already in UTC.
  defp to_datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp to_datetime(_at), do: nil
end
