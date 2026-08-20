defmodule Mix.Tasks.Openagents.Config.Readiness do
  use Mix.Task

  @shortdoc "Print the redacted runtime configuration readiness report"

  @impl Mix.Task
  def run(_arguments) do
    OpenAgents.RuntimeConfig.print_readiness!()
  end
end
