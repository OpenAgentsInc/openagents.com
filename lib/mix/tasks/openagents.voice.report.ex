defmodule Mix.Tasks.Openagents.Voice.Report do
  use Mix.Task

  @shortdoc "Write a transcript-free aggregate voice release report"

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} =
      OptionParser.parse(arguments, strict: [since_hours: :integer, output: :string])

    if invalid != [] or remaining != [], do: Mix.raise("invalid voice-report options")

    hours = Keyword.get(options, :since_hours, 24)
    if hours not in 1..2_160, do: Mix.raise("--since-hours must be between 1 and 2160")

    start_read_only_application()

    report =
      OpenAgents.Voice.Operations.Report.build(DateTime.add(DateTime.utc_now(), -hours, :hour))

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(options, :output) do
      nil ->
        Mix.shell().info(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end

  defp start_read_only_application do
    Application.put_env(:openagents, :turn_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_recovery_worker_enabled, false)
    Application.put_env(:openagents, :voice_retention_worker_enabled, false)
    Mix.Task.run("app.start")
  end
end
