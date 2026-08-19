defmodule OpenAgents.Forge do
  @moduledoc false

  def enabled? do
    Application.get_env(:openagents, :forge_enabled, false)
  end
end
