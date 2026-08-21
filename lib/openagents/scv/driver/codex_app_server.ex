defmodule OpenAgents.SCV.Driver.CodexAppServer do
  @moduledoc "Runs the Codex app-server implementation inside an SCV."

  @behaviour OpenAgents.SCV.Driver

  alias OpenAgents.SCV.Executor.CodexAppServer
  alias OpenAgents.SCV.Run

  @impl true
  def id, do: "codex_app_server"

  @impl true
  def required_capabilities(:read_only),
    do: [:model_inference, :network_egress, :process_execute, :workspace_read]

  def required_capabilities(:workspace_write),
    do: required_capabilities(:read_only) ++ [:workspace_write]

  @impl true
  def run(%Run{} = run) do
    options =
      Keyword.merge(run.driver_options,
        run_id: run.id,
        repository_revision: run.repository_revision
      )

    CodexAppServer.run(run.repository, run.objective, options)
  end
end
