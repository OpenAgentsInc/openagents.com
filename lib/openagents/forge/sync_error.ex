defmodule OpenAgents.Forge.SyncError do
  @moduledoc "A typed repository-cache synchronization failure."

  defexception [:repo, :operation, :reason, plug_status: 503]

  @impl true
  def message(%__MODULE__{repo: repo, operation: operation}) do
    "Forge repository #{repo} is temporarily unavailable during #{operation}"
  end
end
