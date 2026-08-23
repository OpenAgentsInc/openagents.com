defmodule OpenAgents.Tools.RedactionTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Tools.Redaction

  test "redacts nested credentials without changing ordinary tool data" do
    assert Redaction.redact(%{
             "content" => "safe",
             "metadata" => %{"api_key" => "secret", "repository" => "owner/repo"},
             token: "secret"
           }) == %{
             "content" => "safe",
             "metadata" => %{"api_key" => "[REDACTED]", "repository" => "owner/repo"},
             token: "[REDACTED]"
           }
  end
end
