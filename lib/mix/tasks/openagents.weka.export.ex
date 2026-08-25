defmodule Mix.Tasks.Openagents.Weka.Export do
  @shortdoc "Export consenting thread transcripts as a WEKA trace corpus"

  @moduledoc """
  Builds the WEKA v1 trace corpus the benchmark workbench replays
  (`docs/2026-08-24-benchmark-workbench-agentx.md`, section 5; issue #218).

  The thread-id set is an input, not a query. Nothing here selects threads on
  the operator's behalf, because a corpus is only reproducible if the set that
  built it was recorded, and because a query is how a consent gate gets widened
  by accident. Name the ids, or name a file of them:

      mix openagents.weka.export --threads corpus-set.txt --out corpus.json

      mix openagents.weka.export --thread THREAD_ID --thread THREAD_ID \\
        --out /tmp/corpus.json --salt CORPUS_SALT

  A thread whose owner has not widened it is refused, recorded in the corpus by
  id and reason, and contributes nothing. The written document carries the
  requested set and the code revision that produced it, so the same file can be
  rebuilt and compared byte for byte.

  Publication is a separate, explicit decision. This task writes a file.
  """

  use Mix.Task

  alias OpenAgents.Threads.WekaExport

  @requirements ["app.config"]

  @switches [
    thread: :keep,
    threads: :string,
    out: :string,
    salt: :string,
    revision: :string,
    database_url: :string
  ]

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} = OptionParser.parse(arguments, strict: @switches)

    if remaining != [] or invalid != [], do: Mix.raise("invalid WEKA export options")

    thread_ids = thread_ids(options)
    if thread_ids == [], do: Mix.raise("--thread THREAD_ID or --threads FILE is required")

    ensure_repo(Keyword.get(options, :database_url))

    build_options =
      options
      |> Keyword.take([:salt, :revision])
      |> Keyword.new()

    {:ok, corpus} = WekaExport.corpus(thread_ids, build_options)

    output = Keyword.get(options, :out, "openagents-weka-corpus.json")
    File.write!(output, Jason.encode!(corpus, pretty: true))

    reuse = corpus["prefix_reuse"]

    Mix.shell().info(
      "wrote #{output}: #{length(corpus["traces"])} trace(s), " <>
        "#{length(corpus["refused"])} refused, #{reuse["requests"]} request(s), " <>
        "#{reuse["blocks"]} block(s), prefix reuse " <>
        "#{Float.round(reuse["rate"] * 100, 1)}%, revision #{corpus["code_revision"]}"
    )

    for refusal <- corpus["refused"] do
      Mix.shell().info("  refused #{refusal["thread_id"]}: #{refusal["reason"]}")
    end
  end

  defp thread_ids(options) do
    named = for {:thread, id} <- options, do: String.trim(id)

    from_file =
      case Keyword.get(options, :threads) do
        nil ->
          []

        path ->
          path
          |> File.read!()
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      end

    Enum.uniq(from_file ++ named)
  end

  # Inside the application — a test, a release console — the repository is
  # already up and starting a second one would take a connection outside the
  # caller's ownership. Outside it, start only the repository: this task has no
  # use for the supervision tree's recovery workers.
  defp ensure_repo(database_url) do
    if Process.whereis(OpenAgents.Repo) do
      :ok
    else
      start_repo_only(database_url)
    end
  end

  defp start_repo_only(database_url) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    repo_options =
      case database_url do
        nil -> [pool_size: 2]
        url when is_binary(url) -> [url: url, pool_size: 2, ssl: false]
      end

    case OpenAgents.Repo.start_link(repo_options) do
      {:ok, _repo} -> :ok
      {:error, {:already_started, _repo}} -> :ok
      {:error, reason} -> Mix.raise("repo start failed: #{inspect(reason)}")
    end
  end
end
