defmodule OpenAgents.OperationalLogTest do
  use ExUnit.Case, async: true

  alias OpenAgents.OperationalLog

  test "arbitrary failure details reduce to bounded codes" do
    assert OperationalLog.code({:provider_failed, "private prompt sentinel"}) ==
             "provider_failed"

    assert OperationalLog.code(%RuntimeError{message: "credential sentinel"}) == "runtime_error"
    assert OperationalLog.code("raw failure with a token") == "other"
  end
end
