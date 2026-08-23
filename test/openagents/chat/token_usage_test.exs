defmodule OpenAgents.Chat.TokenUsageTest do
  @moduledoc """
  The chat console reports token counts twice — once per turn, once for the
  conversation — and the two surfaces disagreed in production: every turn's line
  omitted reasoning while the running list read `Reasoning 0`. Both now ask this
  module, and a turn's line is the report over a list of one, so the cases below
  each assert the whole-conversation answer and the per-turn answer together.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Chat.TokenUsage

  defp reasoning(usages), do: Enum.find(TokenUsage.counts(usages), &(elem(&1, 0) == :reasoning))

  test "a reported positive count reaches both the turn and the conversation" do
    usage = %{input: 24, output: 8, reasoning: 3, cached: 4, total: 32}

    assert reasoning([usage]) == {:reasoning, "Reasoning", 3}
    assert reasoning([usage, usage]) == {:reasoning, "Reasoning", 6}
  end

  test "a count every turn reported as zero stays a reported zero" do
    usage = %{input: 24, output: 8, reasoning: 0, cached: 4, total: 32}

    assert reasoning([usage]) == {:reasoning, "Reasoning", 0}
    assert reasoning([usage, usage]) == {:reasoning, "Reasoning", 0}
  end

  test "a count no turn reported stays off both reports" do
    usage = %{input: 24, output: 8, reasoning: nil, cached: 4, total: 32}

    assert reasoning([usage]) == nil
    assert reasoning([usage, usage]) == nil
  end

  test "a zero beside an unreported count reports nothing rather than a count of none" do
    measured = %{input: 24, output: 8, reasoning: 0, cached: 4, total: 32}
    unreported = %{input: 30, output: 10, reasoning: nil, cached: 2, total: 40}

    assert reasoning([measured]) == {:reasoning, "Reasoning", 0}
    assert reasoning([unreported]) == nil
    assert reasoning([measured, unreported]) == nil
  end

  test "a positive count survives a turn that reported none of that kind" do
    measured = %{input: 24, output: 8, reasoning: 3, cached: 4, total: 32}
    unreported = %{input: 30, output: 10, reasoning: nil, cached: 2, total: 40}

    assert reasoning([measured, unreported]) == {:reasoning, "Reasoning", 3}
  end

  test "counts keep their display order and drop only the kinds nothing reported" do
    usage = %{input: 24, output: 8, reasoning: nil, cached: 4, total: 32}

    assert TokenUsage.counts([usage]) == [
             {:input, "Input", 24},
             {:output, "Output", 8},
             {:cached, "Cached", 4}
           ]
  end

  test "a total says whether the provider reported it" do
    reported = %{input: 24, output: 8, reasoning: nil, cached: nil, total: 32}
    derived = %{input: 24, output: 8, reasoning: nil, cached: nil, total: nil}

    assert TokenUsage.total([]) == nil
    assert TokenUsage.total([reported]) == {32, :reported}
    assert TokenUsage.total([derived]) == {32, :derived}
    assert TokenUsage.total([reported, derived]) == {64, :derived}
  end
end
