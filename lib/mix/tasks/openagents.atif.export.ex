defmodule Mix.Tasks.Openagents.Atif.Export do
  @shortdoc "Export one account's conversation as an ATIF v1.7 trajectory file"

  @moduledoc """
  Exports the same ATIF document as `GET /data/export/atif` without starting
  the OpenAgents supervision tree or its recovery workers.

      mix openagents.atif.export --github-id 14167547 --out /tmp/atif.json \
        --database-url postgres://openagents_app:URL_ENCODED_PASSWORD@127.0.0.1:5433/openagents
  """

  use Mix.Task

  import Ecto.Query

  @requirements ["app.config"]

  @impl Mix.Task
  def run(arguments) do
    {options, remaining, invalid} =
      OptionParser.parse(arguments,
        strict: [github_id: :integer, out: :string, database_url: :string]
      )

    if remaining != [] or invalid != [], do: Mix.raise("invalid ATIF export options")

    github_id =
      Keyword.get(options, :github_id) || Mix.raise("--github-id GITHUB_NUMERIC_ID is required")

    start_repo_only(Keyword.get(options, :database_url))

    user =
      OpenAgents.Repo.get_by(OpenAgents.Accounts.User, github_id: github_id) ||
        Mix.raise("no user with GitHub ID #{github_id}")

    conversation =
      OpenAgents.Repo.one(
        from(conversation in OpenAgents.Conversations.Conversation,
          join: visitor in OpenAgents.Conversations.Visitor,
          on: visitor.id == conversation.visitor_id,
          where: visitor.user_id == ^user.id,
          order_by: [asc: conversation.inserted_at],
          limit: 1
        )
      ) || Mix.raise("user #{github_id} has no conversation")

    visitor = OpenAgents.Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    {:ok, export} = OpenAgents.DataRights.AtifExport.build(user, visitor, conversation)
    output = Keyword.get(options, :out, "openagents-conversation-#{conversation.id}-atif.json")
    File.write!(output, Jason.encode!(export, pretty: true))

    steps = export["steps"]
    tool_calls = steps |> Enum.flat_map(&(&1["tool_calls"] || [])) |> length()

    Mix.shell().info(
      "wrote #{output}: #{length(steps)} steps, #{tool_calls} tool calls, " <>
        "final_metrics=#{Jason.encode!(export["final_metrics"])}"
    )
  end

  defp start_repo_only(database_url) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    _snapshot = OpenAgents.Tools.Registry.install!(Application.fetch_env!(:openagents, :tools))

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
