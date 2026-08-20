defmodule OpenAgents.Voice.UsageTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Voice.Usage

  setup do
    previous_tokens = Application.fetch_env!(:openagents, :voice_maximum_session_tokens)
    previous_cost = Application.fetch_env!(:openagents, :voice_maximum_estimated_cost_microusd)
    Application.put_env(:openagents, :voice_maximum_session_tokens, 1_000)
    Application.put_env(:openagents, :voice_maximum_estimated_cost_microusd, 10_000)

    on_exit(fn ->
      Application.put_env(:openagents, :voice_maximum_session_tokens, previous_tokens)
      Application.put_env(:openagents, :voice_maximum_estimated_cost_microusd, previous_cost)
    end)

    :ok
  end

  test "near_budget?/1 trips at 80% of either ceiling and over_budget?/1 only at the ceiling" do
    refute Usage.near_budget?(%{"total_tokens" => 799, "estimated_cost_microusd" => 0})
    assert Usage.near_budget?(%{"total_tokens" => 800, "estimated_cost_microusd" => 0})
    refute Usage.over_budget?(%{"total_tokens" => 999, "estimated_cost_microusd" => 0})
    assert Usage.over_budget?(%{"total_tokens" => 1_000, "estimated_cost_microusd" => 0})

    refute Usage.near_budget?(%{"total_tokens" => 0, "estimated_cost_microusd" => 7_999})
    assert Usage.near_budget?(%{"total_tokens" => 0, "estimated_cost_microusd" => 8_000})
    assert Usage.over_budget?(%{"total_tokens" => 0, "estimated_cost_microusd" => 10_000})
  end

  test "empty usage is neither near nor over budget" do
    refute Usage.near_budget?(%{})
    refute Usage.over_budget?(%{})
  end
end
