defmodule OpenAgents.Accounts.OperatorConfigTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Accounts.OperatorConfig

  test "parses unique immutable GitHub IDs" do
    assert OperatorConfig.parse_github_ids!("14167547, 42,14167547") == [14_167_547, 42]
  end

  test "refuses empty, textual, and nonpositive identities" do
    assert_raise ArgumentError, fn -> OperatorConfig.parse_github_ids!("") end
    assert_raise ArgumentError, fn -> OperatorConfig.parse_github_ids!("octocat") end
    assert_raise ArgumentError, fn -> OperatorConfig.parse_github_ids!("0") end
  end
end
