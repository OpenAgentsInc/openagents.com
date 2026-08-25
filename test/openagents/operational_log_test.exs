defmodule OpenAgents.OperationalLogTest do
  use ExUnit.Case, async: true

  alias OpenAgents.OperationalLog

  test "arbitrary failure details reduce to bounded codes" do
    assert OperationalLog.code({:provider_failed, "private prompt sentinel"}) ==
             "provider_failed"

    assert OperationalLog.code(%RuntimeError{message: "credential sentinel"}) == "runtime_error"
    assert OperationalLog.code("raw failure with a token") == "other"
  end

  describe "status/1" do
    test "surfaces a plain upstream HTTP status" do
      assert OperationalLog.status({:http_status, 429}) == 429
      assert OperationalLog.status({:http_status, 401}) == 401
      assert OperationalLog.status({:anything, 503}) == 503
    end

    test "refuses anything that is not a plain HTTP status" do
      # A detail that could carry a prompt, a key, or a body never gets through.
      assert OperationalLog.status({:http_status, "429 Too Many Requests"}) == nil
      assert OperationalLog.status({:provider_error, %{"key" => "sk-secret"}}) == nil
      assert OperationalLog.status({:http_status, 99}) == nil
      assert OperationalLog.status({:http_status, 600}) == nil
      assert OperationalLog.status(:timeout) == nil
      assert OperationalLog.status("boom") == nil
    end
  end
end
