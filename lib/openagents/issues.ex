defmodule OpenAgents.Issues do
  @moduledoc "Repository-scoped issues, comments, labels, milestones, and assignees."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.{Comment, Issue}
  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label
  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  def list_issues(opts \\ []) when is_list(opts),
    do: list_issues(Repositories.initial_repository!(), opts)

  def list_issues(%Repository{id: repository_id}, opts) when is_list(opts) do
    state = Keyword.get(opts, :state, "open")

    Issue
    |> where(repository_id: ^repository_id)
    |> maybe_filter_state(state)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_issue!(id), do: get_issue!(Repositories.initial_repository!(), id)

  def get_issue!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Issue, id: id, repository_id: repository_id)
  end

  def get_issue_by_number!(number) when is_integer(number),
    do: get_issue_by_number!(Repositories.initial_repository!(), number)

  def get_issue_by_number!(%Repository{id: repository_id}, number) when is_integer(number),
    do: Repo.get_by!(Issue, repository_id: repository_id, number: number)

  def get_issue_by_path!(owner, repository_name, number) when is_integer(number) do
    Repo.one!(
      from issue in Issue,
        join: repository in Repository,
        on: repository.id == issue.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and issue.number == ^number
    )
  end

  def create_issue(attrs \\ %{}),
    do: create_issue(Repositories.initial_repository!(), attrs, nil)

  def create_issue(%Repository{} = repository, attrs),
    do: create_issue(repository, attrs, nil)

  def create_issue(%Repository{} = repository, attrs, author)
      when is_nil(author) or is_struct(author, User) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put("repository_id", repository.id)
      |> put_author(author)
      |> prepare_collections(repository)

    create_issue_with_number(repository, normalized, 20)
  end

  defp create_issue_with_number(repository, normalized, attempts_remaining) do
    Repo.transaction(fn ->
      number = next_issue_number(repository.id)
      normalized = Map.put(normalized, "number", number)

      with {:ok, issue} <- %Issue{} |> Issue.changeset(normalized) |> Repo.insert(),
           :ok <- sync_label_relationships(issue),
           :ok <- sync_assignee_relationships(issue) do
        issue
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:error, changeset} when attempts_remaining > 1 ->
        if number_conflict?(changeset, "issues_repository_id_number_index") do
          create_issue_with_number(repository, normalized, attempts_remaining - 1)
        else
          {:error, changeset}
        end

      result ->
        result
    end
  end

  def update_issue(%Issue{} = issue, attrs) do
    repository = %Repository{id: issue.repository_id}

    Repo.transaction(fn ->
      normalized =
        issue
        |> maybe_closed_attrs(attrs)
        |> to_string_map()
        |> Map.drop(["number", "repository_id", "author_user_id", "user"])
        |> prepare_collections(repository)

      with {:ok, updated} <- issue |> Issue.changeset(normalized) |> Repo.update(),
           :ok <- sync_label_relationships(updated),
           :ok <- sync_assignee_relationships(updated) do
        updated
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    attrs =
      if is_nil(issue.repository_id) do
        attrs
        |> to_string_map()
        |> Map.put("repository_id", Repositories.initial_repository!().id)
      else
        attrs
      end

    Issue.changeset(issue, attrs)
  end

  def add_labels(%Issue{} = issue, names) when is_list(names) do
    new_labels =
      Enum.map(names, fn name ->
        issue.repository_id
        |> repository_stub()
        |> Labels.get_label_by_name!(name)
        |> label_json()
      end)

    labels = ((issue.labels || []) ++ new_labels) |> Enum.uniq_by(& &1["name"])
    update_issue(issue, %{"labels" => labels})
  end

  def remove_label(%Issue{} = issue, name) when is_binary(name) do
    decoded = URI.decode(name)
    labels = Enum.reject(issue.labels || [], &label_match?(&1, decoded))
    update_issue(issue, %{"labels" => labels})
  end

  def add_assignees(%Issue{} = issue, logins) when is_list(logins) do
    repository = repository_stub(issue.repository_id)

    new =
      Enum.map(logins, fn login ->
        repository
        |> Repositories.get_assignable_user_by_login!(login)
        |> assignee_json()
      end)

    assignees = ((issue.assignees || []) ++ new) |> Enum.uniq_by(& &1["login"])
    update_issue(issue, %{"assignees" => assignees})
  end

  def remove_assignees(%Issue{} = issue, logins) when is_list(logins) do
    logins = logins |> Enum.map(&String.downcase/1) |> MapSet.new()

    assignees =
      Enum.reject(issue.assignees || [], fn assignee ->
        String.downcase(assignee["login"]) in logins
      end)

    update_issue(issue, %{"assignees" => assignees})
  end

  def set_milestone(%Issue{} = issue, nil) do
    update_issue(issue, %{"milestone" => nil})
  end

  def set_milestone(%Issue{} = issue, number) when is_integer(number) do
    milestone = Milestones.get_milestone_by_number!(repository_stub(issue.repository_id), number)
    update_issue(issue, %{"milestone" => milestone_json(milestone)})
  end

  def list_comments(%Issue{id: issue_id, repository_id: repository_id}) do
    Comment
    |> where(issue_id: ^issue_id, repository_id: ^repository_id)
    |> order_by(:created_at)
    |> Repo.all()
  end

  def list_comments(issue_id) do
    issue = get_issue!(issue_id)
    list_comments(issue)
  end

  def get_comment!(id), do: get_comment!(Repositories.initial_repository!(), id)

  def get_comment!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Comment, id: id, repository_id: repository_id)
  end

  def get_comment_by_path!(owner, repository_name, id) do
    Repo.one!(
      from comment in Comment,
        join: repository in Repository,
        on: repository.id == comment.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and comment.id == ^id
    )
  end

  def create_comment(attrs \\ %{}) do
    normalized = to_string_map(attrs)

    case Map.fetch(normalized, "issue_id") do
      {:ok, issue_id} ->
        issue = get_issue!(issue_id)
        create_comment(issue, normalized, nil)

      :error ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %Comment{}
        |> Comment.changeset(
          normalized
          |> Map.put("repository_id", Repositories.initial_repository!().id)
          |> Map.put_new("created_at", now)
          |> Map.put_new("updated_at", now)
        )
        |> Ecto.Changeset.apply_action(:insert)
    end
  end

  def create_comment(%Issue{} = issue, attrs, author \\ nil)
      when is_nil(author) or is_struct(author, User) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put("issue_id", issue.id)
      |> Map.put("repository_id", issue.repository_id)
      |> put_author(author)
      |> Map.put_new("created_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    Repo.transaction(fn ->
      with {:ok, %Comment{} = comment} <-
             %Comment{} |> Comment.changeset(normalized) |> Repo.insert(),
           {1, nil} <-
             from(i in Issue,
               where: i.id == ^issue.id and i.repository_id == ^issue.repository_id,
               update: [inc: [comments: 1]]
             )
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
      |> Map.drop(["issue_id", "repository_id", "author_user_id", "user"])
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    comment
    |> Comment.changeset(normalized)
    |> Repo.update()
  end

  def delete_comment(%Comment{} = comment) do
    Repo.transaction(fn ->
      with {:ok, %Comment{}} <- Repo.delete(comment),
           {1, nil} <-
             from(i in Issue,
               where: i.id == ^comment.issue_id and i.repository_id == ^comment.repository_id,
               update: [inc: [comments: -1]]
             )
             |> Repo.update_all([]) do
        :ok
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {_, _} -> Repo.rollback(:ok)
      end
    end)
  end

  defp prepare_collections(attrs, repository) do
    attrs
    |> maybe_convert_milestone(repository)
    |> maybe_convert_labels(repository)
    |> maybe_convert_assignees(repository)
  end

  defp maybe_convert_milestone(%{"milestone" => nil} = attrs, _repository) do
    attrs |> Map.put("milestone", nil) |> Map.put("milestone_id", nil)
  end

  defp maybe_convert_milestone(%{"milestone" => number} = attrs, repository)
       when is_integer(number) do
    milestone = Milestones.get_milestone_by_number!(repository, number)

    attrs
    |> Map.put("milestone", milestone_json(milestone))
    |> Map.put("milestone_id", milestone.id)
  end

  defp maybe_convert_milestone(%{"milestone" => milestone} = attrs, repository)
       when is_map(milestone) do
    number = milestone["number"] || milestone[:number]
    maybe_convert_milestone(Map.put(attrs, "milestone", number), repository)
  end

  defp maybe_convert_milestone(attrs, _repository), do: attrs

  defp maybe_convert_labels(%{"labels" => labels} = attrs, repository) when is_list(labels) do
    snapshots =
      Enum.map(labels, fn label ->
        name = if is_binary(label), do: label, else: label["name"] || label[:name]
        repository |> Labels.get_label_by_name!(name) |> label_json()
      end)

    Map.put(attrs, "labels", Enum.uniq_by(snapshots, & &1["name"]))
  end

  defp maybe_convert_labels(attrs, _repository), do: attrs

  defp maybe_convert_assignees(%{"assignees" => assignees} = attrs, repository)
       when is_list(assignees) do
    snapshots =
      Enum.map(assignees, fn assignee ->
        login = if is_binary(assignee), do: assignee, else: assignee["login"] || assignee[:login]
        repository |> Repositories.get_assignable_user_by_login!(login) |> assignee_json()
      end)

    Map.put(attrs, "assignees", Enum.uniq_by(snapshots, & &1["login"]))
  end

  defp maybe_convert_assignees(attrs, _repository), do: attrs

  defp sync_label_relationships(%Issue{} = issue) do
    Repo.delete_all(from row in "issue_labels", where: row.issue_id == ^issue.id)

    rows =
      Enum.map(issue.labels || [], fn snapshot ->
        label = Labels.get_label_by_name!(repository_stub(issue.repository_id), snapshot["name"])

        %{
          issue_id: issue.id,
          label_id: label.id,
          repository_id: issue.repository_id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    if rows != [], do: Repo.insert_all("issue_labels", dump_repository_ids(rows))
    :ok
  end

  defp sync_assignee_relationships(%Issue{} = issue) do
    Repo.delete_all(from row in "issue_assignees", where: row.issue_id == ^issue.id)

    rows =
      Enum.map(issue.assignees || [], fn snapshot ->
        user =
          Repositories.get_assignable_user_by_login!(
            repository_stub(issue.repository_id),
            snapshot["login"]
          )

        %{
          issue_id: issue.id,
          user_id: user.id,
          repository_id: issue.repository_id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    if rows != [], do: Repo.insert_all("issue_assignees", dump_repository_ids(rows))
    :ok
  end

  defp next_issue_number(repository_id) do
    case Repo.aggregate(from(i in Issue, where: i.repository_id == ^repository_id), :max, :number) do
      nil -> 1
      number -> number + 1
    end
  end

  defp number_conflict?(%Ecto.Changeset{} = changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == constraint_name
    end)
  end

  defp put_author(attrs, nil), do: attrs

  defp put_author(attrs, %User{} = author) do
    attrs
    |> Map.put("author_user_id", author.id)
    |> Map.put("user", user_json(author))
  end

  defp dump_repository_ids(rows) do
    Enum.map(rows, fn row ->
      row = Map.update!(row, :repository_id, &Ecto.UUID.dump!/1)

      if Map.has_key?(row, :user_id) do
        Map.update!(row, :user_id, &Ecto.UUID.dump!/1)
      else
        row
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
    attrs |> Map.put("closed_at", nil) |> Map.put("state_reason", nil)
  end

  defp maybe_closed_attrs(issue, %{state: "closed"} = attrs) do
    attrs =
      if issue.state == "open" and is_nil(attrs[:closed_at]) do
        Map.put(attrs, :closed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      else
        attrs
      end

    Map.put_new(attrs, :state_reason, "completed")
  end

  defp maybe_closed_attrs(_issue, %{state: "open"} = attrs) do
    attrs |> Map.put(:closed_at, nil) |> Map.put(:state_reason, nil)
  end

  defp maybe_closed_attrs(_issue, attrs), do: attrs

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, state: ^state)

  defp to_string_map(attrs) do
    for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
  end

  defp repository_stub(id), do: %Repository{id: id}

  defp label_json(%Label{} = label) do
    %{
      "id" => label.id,
      "name" => label.name,
      "color" => label.color,
      "description" => label.description
    }
  end

  defp milestone_json(%Milestone{} = milestone) do
    %{
      "number" => milestone.number,
      "title" => milestone.title,
      "state" => milestone.state,
      "description" => milestone.description,
      "due_on" => milestone.due_on
    }
  end

  defp user_json(%User{} = user) do
    %{
      "id" => user.github_id,
      "login" => user.github_login,
      "avatar_url" => user.github_avatar_url
    }
  end

  defp assignee_json(%User{} = user), do: %{"login" => user.github_login}
  defp label_match?(label, name), do: label["name"] == name
end
