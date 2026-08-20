defmodule Mix.Tasks.Openagents.Voice.LoadProbe do
  use Mix.Task

  @shortdoc "Run a bounded readiness load probe"

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} =
      OptionParser.parse(arguments,
        strict: [url: :string, requests: :integer, concurrency: :integer, output: :string]
      )

    if invalid != [] or remaining != [], do: Mix.raise("invalid load-probe arguments")

    url = Keyword.fetch!(options, :url)
    requests = Keyword.get(options, :requests, 100)
    concurrency = Keyword.get(options, :concurrency, 10)

    case Application.ensure_all_started(:req) do
      {:ok, _applications} -> :ok
      {:error, reason} -> Mix.raise("could not start Req: #{inspect(reason)}")
    end

    report = OpenAgents.Voice.Operations.LoadProbe.run(url, requests, concurrency)
    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(options, :output) do
      nil ->
        Mix.shell().info(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end
end
