defmodule OpenAgentsWeb.RelativeTimeTest do
  @moduledoc """
  The one relative-time answer every recency surface reads (#27).

  The scale is the contract: minutes for the first hour, hours for the first
  day, days after that. A commit pushed moments ago has to read in minutes
  rather than as a calendar date, and the exact moment has to survive in the
  forms a `title` and a `datetime` attribute need.
  """
  use ExUnit.Case, async: true

  alias OpenAgentsWeb.RelativeTime

  defp seconds_ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "since/1" do
    test "a moment seconds old still reads as a whole minute" do
      assert RelativeTime.since(seconds_ago(5)) == "1m"
    end

    test "the first hour reads in minutes" do
      assert RelativeTime.since(seconds_ago(5 * 60)) == "5m"
      assert RelativeTime.since(seconds_ago(59 * 60)) == "59m"
    end

    test "the first day degrades to hours" do
      assert RelativeTime.since(seconds_ago(3_600)) == "1h"
      assert RelativeTime.since(seconds_ago(23 * 3_600)) == "23h"
    end

    test "beyond a day it degrades to days" do
      assert RelativeTime.since(seconds_ago(86_400)) == "1d"
      assert RelativeTime.since(seconds_ago(9 * 86_400)) == "9d"
    end

    test "a naive stamp is read as UTC" do
      naive = NaiveDateTime.add(NaiveDateTime.utc_now(), -7_200, :second)
      assert RelativeTime.since(naive) == "2h"
    end

    test "an ISO 8601 commit stamp is read as Git writes it" do
      stamp = seconds_ago(2 * 86_400) |> DateTime.to_iso8601()
      assert RelativeTime.since(stamp) == "2d"
    end

    test "an unreadable moment renders nothing rather than guessing" do
      assert RelativeTime.since(nil) == nil
      assert RelativeTime.since("not a stamp") == nil
    end
  end

  describe "ago/1" do
    test "adds the word a reader expects after the span" do
      assert RelativeTime.ago(seconds_ago(4 * 3_600)) == "4h ago"
    end

    test "says nothing when there is no moment to describe" do
      assert RelativeTime.ago(nil) == nil
    end
  end

  describe "exact/1 and machine/1" do
    test "the precise moment survives the coarse span" do
      at = ~U[2026-08-22 14:31:07Z]

      assert RelativeTime.exact(at) == "2026-08-22 14:31 UTC"
      assert RelativeTime.machine(at) == "2026-08-22T14:31:07Z"
    end

    test "an offset stamp is normalized to UTC before it is shown" do
      assert RelativeTime.exact("2026-08-22T16:31:07+02:00") == "2026-08-22 14:31 UTC"
    end

    test "nothing to show is nothing to render" do
      assert RelativeTime.exact(nil) == nil
      assert RelativeTime.machine(nil) == nil
    end
  end
end
