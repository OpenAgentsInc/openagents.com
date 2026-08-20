defmodule OpenAgentsWeb.AllowedOriginsTest do
  use ExUnit.Case, async: true
  alias OpenAgentsWeb.AllowedOrigins

  test "includes the primary host and configured Cloud Run aliases" do
    assert AllowedOrigins.for_production(
             "openagents.example",
             "https://openagents-123.run.app, https://openagents.example"
           ) == ["https://openagents.example", "https://openagents-123.run.app"]
  end

  test "rejects origins containing paths or an insecure scheme" do
    assert_raise ArgumentError, fn ->
      AllowedOrigins.for_production("openagents.example", "https://other.example/path")
    end

    assert_raise ArgumentError, fn ->
      AllowedOrigins.for_production("openagents.example", "http://other.example")
    end
  end
end
