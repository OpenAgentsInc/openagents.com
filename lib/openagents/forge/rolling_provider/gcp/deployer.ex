defmodule OpenAgents.Forge.RollingProvider.Gcp.Deployer do
  @moduledoc """
  Starts the minimal private BEAM node used for Google Cloud replacement calls.

  The deployer container starts this module with the release's clean boot file.
  It does not start the OpenAgents application, join Ra, open an HTTP listener,
  or connect to PostgreSQL. It starts only the dependencies needed by `Req` and
  then waits for bounded `erpc` calls from the three-node staging fleet.
  """

  @sha_pattern ~r/\A[0-9a-f]{40}\z/

  @doc false
  def start do
    expected_revision = System.fetch_env!("OPENAGENTS_CONTROLLER_SHA")

    unless Regex.match?(@sha_pattern, expected_revision) and
             expected_revision == OpenAgents.BuildInfo.revision() do
      raise "deployer image revision does not match its assigned Git SHA"
    end

    {:ok, _applications} = Application.ensure_all_started(:req)
    Process.sleep(:infinity)
  end
end
