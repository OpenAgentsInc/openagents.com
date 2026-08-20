defmodule OpenAgents.Test.RollingGcpDriver do
  @moduledoc false

  def replace(instance, sha, digest, config) do
    send(Keyword.fetch!(config, :test_pid), {:gcp_replace, instance, sha, digest})
    Keyword.get(config, :driver_result, :ok)
  end
end
