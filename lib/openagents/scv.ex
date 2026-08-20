defmodule OpenAgents.SCV do
  @moduledoc """
  Runs a bounded SCV through its selected runner and driver.

  The SCV owns the run contract. A driver supplies one coding implementation,
  such as OpenCode, and an environment supplies the admitted runtime
  capabilities. Callers deploy SCVs rather than deploying drivers directly.
  """

  alias OpenAgents.SCV.Run

  @spec run(Run.t()) :: {:ok, map()} | {:error, term()}
  def run(%Run{runner_module: runner} = run), do: runner.run(run)

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repository, objective, options \\ []) do
    with {:ok, run} <- Run.new(repository, objective, options) do
      run(run)
    end
  end
end
