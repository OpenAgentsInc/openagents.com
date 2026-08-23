defmodule Mix.Tasks.Openagents.Promises.Backfill do
  @moduledoc """
  Backfills the reviewed product promise set into a forge project.

  Run this task with `--owner`, `--repo`, and `--project-number`. The curated
  input lives in `priv/promises/curated.json`, and rerunning the task skips
  promises that already have a project item.
  """

  use Mix.Task

  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Projects.PromiseRegistry
  alias OpenAgents.Repositories
  alias OpenAgents.Issues.Issue

  @shortdoc "Backfill the curated product promise registry"

  @impl true
  def run(args) do
    Application.ensure_all_started(:openagents)

    {options, []} =
      OptionParser.parse!(args, strict: [owner: :string, repo: :string, project_number: :integer])

    owner = Keyword.fetch!(options, :owner)
    repo_name = Keyword.fetch!(options, :repo)
    project_number = Keyword.fetch!(options, :project_number)
    repository = Repositories.get_visible_by_path!(owner, repo_name, nil)
    project = Projects.get_project_by_number!(repository, project_number)

    promise_field_name = ensure_promise_field(project)
    promises = load_promises()

    {created, skipped} =
      Enum.reduce(promises, {0, 0}, fn promise, {created, skipped} ->
        case backfill_promise(repository, project, promise, promise_field_name) do
          :created -> {created + 1, skipped}
          :skipped -> {created, skipped + 1}
        end
      end)

    Mix.shell().info("Backfilled #{created} promise(s); skipped #{skipped}.")
  rescue
    KeyError -> Mix.raise("Pass --owner, --repo, and --project-number.")
    Ecto.NoResultsError -> Mix.raise("The repository or project does not exist.")
  end

  defp ensure_promise_field(project) do
    unless PromiseRegistry.registry?(project) do
      case Projects.create_project_field(%{
             project_id: project.id,
             name: "Promise state",
             data_type: "promise_state",
             options: %{"values" => PromiseRegistry.states()}
           }) do
        {:ok, _field} ->
          "Promise state"

        {:error, changeset} ->
          Mix.raise("Could not create promise state field: #{inspect(changeset.errors)}")
      end
    else
      PromiseRegistry.field(project).name
    end
  end

  defp backfill_promise(repository, project, promise, promise_field_name) do
    if existing_promise?(project, promise["id"]) do
      :skipped
    else
      issue = canonical_issue(repository, promise)
      values = promise_values(promise, promise_field_name)

      case Projects.create_project_item(
             %{"issue_number" => issue.number, "values" => values},
             project
           ) do
        {:ok, _item} ->
          :created

        {:error, changeset} ->
          if gate_failure?(changeset) do
            Mix.shell().info(
              "Skipped #{promise["id"]}: LIVE gate failed: #{format_errors(changeset.errors)}"
            )

            :skipped
          else
            Mix.raise("Could not create #{promise["id"]}: #{inspect(changeset.errors)}")
          end
      end
    end
  end

  defp existing_promise?(project, id) do
    Projects.list_project_items(project)
    |> Enum.any?(&(get_in(&1.values, ["promise", "id"]) == id))
  end

  defp canonical_issue(repository, promise) do
    marker = "Promise ID: #{promise["id"]}"

    case Issues.list_issues(repository, state: "all")
         |> Enum.find(&String.contains?(&1.body || "", marker)) do
      %Issue{} = issue ->
        issue

      nil ->
        attrs = %{
          title: "Promise: #{promise["id"]}",
          body: "#{marker}\n\n#{promise["claim"]}"
        }

        case Issues.create_issue(repository, attrs) do
          {:ok, issue} -> issue
          {:error, changeset} -> Mix.raise("Could not create issue: #{inspect(changeset.errors)}")
        end
    end
  end

  defp promise_values(promise, promise_field_name) do
    record =
      promise
      |> Map.drop(["state", "evidence"])
      |> Map.put("evidence", promise["evidence"])

    %{promise_field_name => promise["state"], "promise" => record}
  end

  defp gate_failure?(changeset) do
    Enum.any?(changeset.errors, fn
      {:values, {message, _opts}} -> String.contains?(message, "accepted-outcome evidence")
      _error -> false
    end)
  end

  defp format_errors(errors) do
    errors
    |> Enum.map_join(", ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end

  defp load_promises do
    Application.get_env(
      :openagents,
      :promises_curated_path,
      Application.app_dir(:openagents, "priv/promises/curated.json")
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
