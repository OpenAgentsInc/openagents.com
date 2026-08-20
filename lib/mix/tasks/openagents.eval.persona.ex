defmodule Mix.Tasks.Openagents.Eval.Persona do
  use Mix.Task

  @shortdoc "Run the provider-backed Sarah persona regression corpus"

  @moduledoc """
  Runs the committed Sarah persona corpus through the configured OpenAgents
  provider. This task makes billable provider requests.

      mix openagents.eval.persona --output tmp/persona-report.json
  """

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} =
      OptionParser.parse(arguments, strict: [output: :string, model: :string])

    if remaining != [] or invalid != [] do
      Mix.raise("usage: mix openagents.eval.persona [--model MODEL] [--output PATH]")
    end

    Mix.Task.run("app.start")
    provider = Application.fetch_env!(:openagents, :provider)
    model_id = options[:model] || Application.fetch_env!(:openagents, :openai_model)
    output = options[:output] || "tmp/openagents-persona-eval.json"

    case OpenAgents.Persona.Evaluation.Runner.run(provider, model_id) do
      {:ok, report} ->
        write_report!(output, report)

        if report["passed"] do
          Mix.shell().info("persona regression passed: #{report["score"]} (#{output})")
        else
          Mix.raise("persona regression failed: #{report["score"]} (#{output})")
        end

      {:error, reason} ->
        Mix.raise("persona regression could not run: #{inspect(reason)}")
    end
  end

  defp write_report!(path, report) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
  end
end
