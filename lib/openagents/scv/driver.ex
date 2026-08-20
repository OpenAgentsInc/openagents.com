defmodule OpenAgents.SCV.Driver do
  @moduledoc """
  Defines the execution adapter selected for an SCV run.

  Drivers may use different tool protocols, but every driver runs inside the
  same SCV lifecycle, capability, event, and receipt boundary.
  """

  alias OpenAgents.SCV.Run

  @callback id() :: String.t()
  @callback required_capabilities(:read_only | :workspace_write) :: [atom()]
  @callback run(Run.t()) :: {:ok, map()} | {:error, term()}

  @spec fetch(atom() | String.t()) :: {:ok, module()} | {:error, :driver_not_admitted}
  def fetch(driver) when driver in [:opencode, "opencode"],
    do: {:ok, OpenAgents.SCV.Driver.OpenCode}

  def fetch(_driver), do: {:error, :driver_not_admitted}
end
