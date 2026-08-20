defmodule OpenAgents.SCV.Driver.OpenCode do
  @moduledoc "Runs the OpenCode implementation inside an SCV run."

  @behaviour OpenAgents.SCV.Driver

  alias OpenAgents.SCV.Executor.OpenCode
  alias OpenAgents.SCV.Run

  @impl true
  def id, do: "opencode"

  @impl true
  def required_capabilities(:read_only),
    do: [:model_inference, :network_egress, :process_execute, :workspace_read]

  def required_capabilities(:workspace_write),
    do: required_capabilities(:read_only) ++ [:workspace_write]

  @impl true
  def run(%Run{} = run) do
    context = %{
      driver: id(),
      environment: run.environment.id,
      runner: run.runner_id,
      capabilities: Enum.map(run.capabilities, &Atom.to_string/1)
    }

    options =
      Keyword.merge(run.driver_options,
        run_id: run.id,
        permissions: run.permission_profile,
        repository_revision: run.repository_revision,
        event_context: context,
        run_context: context
      )

    OpenCode.run(run.repository, run.objective, options)
  end
end
