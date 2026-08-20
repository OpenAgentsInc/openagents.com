defmodule Mix.Tasks.Openagents.Eval.Recall do
  use Mix.Task

  @shortdoc "Run the deterministic PostgreSQL recall release evaluation"

  @moduledoc """
  Runs the committed synthetic recall corpus and writes a revision-bound
  report. The runner rolls back every fixture row.

      mix openagents.eval.recall --output tmp/openagents-recall-eval.json
  """

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} = OptionParser.parse(arguments, strict: [output: :string])

    if remaining != [] or invalid != [] do
      Mix.raise("usage: mix openagents.eval.recall [--output PATH]")
    end

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    output = options[:output] || "tmp/openagents-recall-eval.json"

    case OpenAgents.Memory.Evaluation.Runner.run() do
      {:ok, report} ->
        write_report!(output, report)

        if report["passed"] do
          Mix.shell().info("recall evaluation passed (#{output})")
        else
          Mix.raise("recall evaluation failed (#{output})")
        end

      {:error, reason} ->
        Mix.raise("recall evaluation could not run: #{inspect(reason)}")
    end
  end

  defp write_report!(path, report) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
  end
end
