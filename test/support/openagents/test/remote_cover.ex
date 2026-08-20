defmodule OpenAgents.Test.RemoteCover do
  @moduledoc false

  def shutdown do
    case Process.whereis(:cover_server) do
      nil -> 5_000
      _pid -> {10_000, node()}
    end
  end
end
