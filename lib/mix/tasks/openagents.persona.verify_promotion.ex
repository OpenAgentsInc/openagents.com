defmodule Mix.Tasks.Openagents.Persona.VerifyPromotion do
  use Mix.Task

  @shortdoc "Verify persona source and regression evidence before promotion"

  @impl Mix.Task
  def run([report_path]) do
    Mix.Task.run("app.start")

    with {:ok, contents} <- File.read(report_path),
         {:ok, report} <- Jason.decode(contents),
         manifest <- OpenAgents.Persona.SourceManifest.load!(),
         persona <- OpenAgents.Persona.current!(),
         corpus <- OpenAgents.Persona.Evaluation.Corpus.load!(),
         :ok <-
           OpenAgents.Persona.Evaluation.ReleaseGate.validate(persona, manifest, corpus, report) do
      Mix.shell().info("promotion evidence passed for #{persona.id} on #{report["model_id"]}")
    else
      {:error, reason} -> Mix.raise("persona promotion blocked: #{inspect(reason)}")
    end
  end

  def run(_arguments),
    do: Mix.raise("usage: mix openagents.persona.verify_promotion REPORT_PATH")
end
