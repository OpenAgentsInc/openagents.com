defmodule OpenAgents.Issues do
  @moduledoc """
  The Issues context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Labels
  alias OpenAgents.Milestones

  def list_issues(opts \\ []) do
    state = Keyword.get(opts, :state, "open")

    Issue
    |> maybe_filter_state(state)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_issue!(id), do: Repo.get!(Issue, id)

  def get_issue_by_number!(number) when is_integer(number),
    do: Repo.get_by!(Issue, number: number)

  def create_issue(attrs \\ %{}) do
    number = next_issue_number()

    normalized =
      attrs
      |> to_string_map()
      |> Map.put("number", number)
      |> prepare_collections()

    %Issue{}
    |> Issue.changeset(normalized)
    |> Repo.insert()
  end

  def update_issue(%Issue{} = issue, attrs) do
    normalized =
      issue
      |> maybe_closed_attrs(attrs)
      |> to_string_map()
      |> prepare_collections()

    issue
    |> Issue.changeset(normalized)
    |> Repo.update()
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end

  def add_labels(%Issue{} = issue, names) when is_list(names) do
    new_labels =
      names
      |> Enum.map(&Labels.get_label_by_name!/1)
      |> Enum.map(&label_json/1)

    existing = issue.labels || []
    labels = (existing ++ new_labels) |> Enum.uniq_by(& &1["name"])
    update_issue(issue, %{"labels" => labels})
  end

  def remove_label(%Issue{} = issue, name) when is_binary(name) do
    name = URI.decode(name)
    labels = Enum.reject(issue.labels || [], &label_match?(&1, name))
    update_issue(issue, %{"labels" => labels})
  end

  def add_assignees(%Issue{} = issue, logins) when is_list(logins) do
    new = Enum.map(logins, &%{"login" => &1})
    existing = issue.assignees || []
    assignees = (existing ++ new) |> Enum.uniq_by(& &1["login"])
    update_issue(issue, %{"assignees" => assignees})
  end

  def remove_assignees(%Issue{} = issue, logins) when is_list(logins) do
    logins = MapSet.new(logins)
    assignees = Enum.reject(issue.assignees || [], & &1["login"] in logins)
    update_issue(issue, %{"assignees" => assignees})
  end

  def set_milestone(%Issue{} = issue, nil) do
    update_issue(issue, %{"milestone" => nil})
  end

  def set_milestone(%Issue{} = issue, number) when is_integer(number) do
    milestone = Milestones.get_milestone_by_number!(number)
    update_issue(issue, %{"milestone" => milestone_json(milestone)})
  end

  def list_comments(issue_id) do
    Comment
    |> where(issue_id: ^issue_id)
    |> order_by(:created_at)
    |> Repo.all()
  end

  def get_comment!(id), do: Repo.get!(Comment, id)

  def create_comment(attrs \\ %{}) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put_new("created_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    issue_id = Map.get(normalized, "issue_id")

    Repo.transaction(fn ->
      with {:ok, %Comment{} = comment} <-
             %Comment{}
             |> Comment.changeset(normalized)
             |> Repo.insert(),
           {1, nil} <-
             from(i in Issue, where: i.id == ^issue_id, update: [inc: [comments: 1]])
             |> Repo.update_all([]) do
        comment
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {_, _} -> Repo.rollback(%Comment{})
      end
    end)
  end

  def update_comment(%Comment{} = comment, attrs) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    comment
    |> Comment.changeset(normalized)
    |> Repo.update()
  end

  def delete_comment(%Comment{} = comment) do
    Repo.transaction(fn ->
      issue_id = comment.issue_id

      with {:ok, %Comment{}} <- Repo.delete(comment),
           {1, nil} <-
             from(i in Issue, where: i.id == ^issue_id, update: [inc: [comments: -1]])
             |> Repo.update_all([]) do
        :ok
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {_, _} -> Repo.rollback(:ok)
      end
    end)
  end

  defp maybe_closed_attrs(issue, %{"state" => "closed"} = attrs) do
    if issue.state == "open" do
      attrs
      |> Map.put("closed_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("state_reason", "completed")
    else
      attrs
    end
  end

  defp maybe_closed_attrs(_issue, %{"state" => "open"} = attrs) do
    attrs
    |> Map.put("closed_at", nil)
    |> Map.put("state_reason", nil)
  end

  defp maybe_closed_attrs(_issue, %{state: "closed"} = attrs) do
    if is_nil(attrs[:closed_at]) do
      Map.put(attrs, :closed_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      attrs
    end
    |> Map.put_new(:state_reason, "completed")
  end

  defp maybe_closed_attrs(_issue, %{state: "open"} = attrs) do
    attrs
    |> Map.put(:closed_at, nil)
    |> Map.put(:state_reason, nil)
  end

  defp maybe_closed_attrs(_issue, attrs), do: attrs

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, state: ^state)

  defp next_issue_number do
    case Repo.aggregate(Issue, :max, :number) do
      nil -> 1
      n -> n + 1
    end
  end

  defp to_string_map(attrs) do
    for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
  end

  defp prepare_collections(attrs) do
    attrs
    |> maybe_convert_milestone()
    |> maybe_convert_labels()
    |> maybe_convert_assignees()
  end

  defp maybe_convert_milestone(%{"milestone" => milestone} = attrs) when is_integer(milestone) do
    milestone = Milestones.get_milestone_by_number!(milestone)
    Map.put(attrs, "milestone", milestone_json(milestone))
  end

  defp maybe_convert_milestone(%{"milestone" => nil} = attrs) do
    Map.put(attrs, "milestone", nil)
  end

  defp maybe_convert_milestone(attrs), do: attrs

  defp maybe_convert_labels(%{"labels" => labels} = attrs) when is_list(labels) do
    if Enum.all?(labels, &is_binary/1) do
      existing =
        Labels.list_labels()
        |> Enum.map(&label_json/1)
        |> Map.new(&{&1["name"], &1})

      label_maps =
        Enum.map(labels, fn name ->
          Map.get(existing, name, %{"name" => name, "color" => "ffffff"})
        end)

      Map.put(attrs, "labels", label_maps)
    else
      attrs
    end
  end

  defp maybe_convert_labels(attrs), do: attrs

  defp maybe_convert_assignees(%{"assignees" => logins} = attrs) when is_list(logins) do
    if Enum.all?(logins, &is_binary/1) do
      assignees = Enum.map(logins, &%{"login" => &1})
      Map.put(attrs, "assignees", assignees)
    else
      attrs
    end
  end

  defp maybe_convert_assignees(attrs), do: attrs

  defp label_json(%OpenAgents.Labels.Label{} = label) do
    %{
      "id" => label.id,
      "name" => label.name,
      "color" => label.color,
      "description" => label.description
    }
  end

  defp milestone_json(%OpenAgents.Milestones.Milestone{} = milestone) do
    %{
      "number" => milestone.number,
      "title" => milestone.title,
      "state" => milestone.state,
      "description" => milestone.description,
      "due_on" => milestone.due_on
    }
  end

  defp label_match?(label, name), do: label["name"] == name
end
