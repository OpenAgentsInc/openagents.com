defmodule OpenAgents.SCV.Runner.Local do
  @moduledoc """
  Runs an SCV driver as a direct child process in the current environment.

  A container platform may place this runner inside an isolated worker image.
  The runner name describes the in-environment process boundary, not the host
  that scheduled the container.
  """

  @behaviour OpenAgents.SCV.Runner

  alias OpenAgents.SCV.Run

  @impl true
  def id, do: "local"

  @impl true
  def run(%Run{driver_module: driver} = run), do: driver.run(run)
end
