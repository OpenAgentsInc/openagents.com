defmodule Mix.Tasks.Openagents.Voice.Retention do
  use Mix.Task

  @shortdoc "Run the bounded voice operational-retention purge"

  @impl Mix.Task
  def run([]) do
    Application.put_env(:openagents, :turn_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_retention_worker_enabled, false)
    Mix.Task.run("app.start")

    case OpenAgents.Voice.Retention.purge_expired() do
      {:ok, count} -> Mix.shell().info(Jason.encode!(%{purged_sessions: count}))
      {:error, reason} -> Mix.raise("voice retention failed: #{inspect(reason)}")
    end
  end

  def run(_arguments), do: Mix.raise("this task accepts no arguments")
end
