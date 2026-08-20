defmodule Mix.Tasks.Openagents.Voice.ReleaseControl do
  use Mix.Task

  @shortdoc "Append a governed voice admission state"

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} =
      OptionParser.parse(arguments,
        strict: [state: :string, reason: :string, actor: :string, revision: :string]
      )

    if invalid != [] or remaining != [], do: Mix.raise("invalid release-control arguments")

    start_operational_application()

    case OpenAgents.Voice.ReleaseControl.append(%{
           state: Keyword.get(options, :state),
           reason: Keyword.get(options, :reason),
           actor: Keyword.get(options, :actor),
           source_revision: Keyword.get(options, :revision)
         }) do
      {:ok, control} ->
        Mix.shell().info(
          Jason.encode!(%{
            schema: "openagents.voice_release_control_result.v1",
            id: control.id,
            state: control.state,
            inserted_at: control.inserted_at
          })
        )

      {:error, changeset} ->
        Mix.raise("release control refused: #{inspect(changeset.errors)}")
    end
  end

  defp start_operational_application do
    Application.put_env(:openagents, :turn_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_retention_worker_enabled, false)
    Mix.Task.run("app.start")
  end
end
