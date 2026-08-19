defmodule OpenAgents.Test.RelupGenServerTest do
  use ExUnit.Case

  alias OpenAgents.Test.RelupGenServer

  test "migrates state through code_change/3" do
    {:ok, pid} = RelupGenServer.start_link(counter: 10)

    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, RelupGenServer, 1, [])
    :ok = :sys.resume(pid)

    assert %RelupGenServer{counter: 11, version: 2} = :sys.get_state(pid)
  end
end
