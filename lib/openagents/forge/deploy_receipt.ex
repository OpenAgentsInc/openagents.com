defmodule OpenAgents.Forge.DeployReceipt do
  @moduledoc false

  defstruct [
    :id,
    :sha,
    :repo,
    :inserted_at,
    :result,
    :push_to_live_ms,
    :modules,
    :nodes,
    :canary
  ]
end
