defmodule OpenAgentsWeb.AllowedOriginsTest do
  use ExUnit.Case, async: true
  alias OpenAgentsWeb.AllowedOrigins

  test "includes the primary host and configured Cloud Run aliases" do
    assert AllowedOrigins.for_production(
             "sarah.example",
             "https://sarah-123.run.app, https://sarah.example"
           ) == ["https://sarah.example", "https://sarah-123.run.app"]
  end

  test "rejects origins containing paths or an insecure scheme" do
    assert_raise ArgumentError, fn ->
      AllowedOrigins.for_production("sarah.example", "https://other.example/path")
    end

    assert_raise ArgumentError, fn ->
      AllowedOrigins.for_production("sarah.example", "http://other.example")
    end
  end
end
