defmodule OpenAgents.Projects do
  @moduledoc "Repository-scoped projects and project items."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Issues.Issue
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  def list_projects, do: list_projects(Repositories.initial_repository!())

  def list_projects(%Repository{id: repository_id}) do
    Project
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :number)
    |> Repo.all()
  end

  def list_projects_by_owner(username) when is_binary(username) do
    repository_id = Repositories.initial_repository!().id

    Repo.all(
      from project in Project,
        where:
          project.repository_id == ^repository_id and
            fragment("lower(?)", project.owner) == ^String.downcase(username),
        order_by: [asc: project.number]
    )
  end

  def get_project!(id), do: get_project!(Repositories.initial_repository!(), id)

  def get_project!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Project, id: id, repository_id: repository_id)
  end

  def get_project_by_number!(number) when is_integer(number),
    do: get_project_by_number!(Repositories.initial_repository!(), number)

  def get_project_by_number!(%Repository{id: repository_id}, number) when is_integer(number),
    do: Repo.get_by!(Project, repository_id: repository_id, number: number)

  def get_project_by_path!(owner, repository_name, number) when is_integer(number) do
    Repo.one!(
      from project in Project,
        join: repository in Repository,
        on: repository.id == project.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and project.number == ^number
    )
  end

  def get_project_by_owner_and_number!(username, number) when is_integer(number) do
    repository_id = Repositories.initial_repository!().id

    Repo.one!(
      from project in Project,
        where:
          project.repository_id == ^repository_id and
            fragment("lower(?)", project.owner) == ^String.downcase(username) and
            project.number == ^number
    )
  end

  def create_project(attrs \\ %{}),
    do: create_project(Repositories.initial_repository!(), attrs, nil)

  def create_project(%Repository{} = repository, attrs),
    do: create_project(repository, attrs, nil)

  def create_project(%Repository{} = repository, attrs, owner_user)
      when is_nil(owner_user) or is_struct(owner_user, User) do
    normalized = to_string_map(attrs)
    explicit_number? = Map.has_key?(normalized, "number")

    normalized =
      normalized
      |> Map.put("repository_id", repository.id)
      |> put_owner(owner_user)

    create_project_with_number(repository, normalized, explicit_number?, owner_user, 20)
  end

  defp create_project_with_number(
         repository,
         normalized,
         explicit_number?,
         owner_user,
         attempts_remaining
       ) do
    normalized = Map.put_new(normalized, "number", next_project_number(repository.id))

    %Project{}
    |> Project.changeset(normalized)
    |> Repo.insert()
    |> case do
      {:error, changeset} when not explicit_number? and attempts_remaining > 1 ->
        if number_conflict?(changeset) do
          normalized = Map.delete(normalized, "number")

          create_project_with_number(
            repository,
            normalized,
            false,
            owner_user,
            attempts_remaining - 1
          )
        else
          {:error, changeset}
        end

      {:ok, project} ->
        Analytics.capture("project_created", actor_distinct_id(owner_user), %{
          "owner" => repository.owner,
          "repo" => repository.name
        })

        {:ok, project}

      result ->
        result
    end
  end

  defp actor_distinct_id(nil), do: Analytics.system_distinct_id("api")
  defp actor_distinct_id(%User{} = actor), do: Analytics.distinct_id(actor)

  def update_project(%Project{} = project, attrs) do
    attrs = attrs |> to_string_map() |> Map.drop(["repository_id", "owner_user_id"])

    attrs =
      if project.owner_user_id do
        Map.drop(attrs, ["owner"])
      else
        attrs
      end

    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project), do: Repo.delete(project)

  def change_project(%Project{} = project, attrs \\ %{}) do
    attrs =
      if is_nil(project.repository_id) do
        attrs
        |> to_string_map()
        |> Map.put("repository_id", Repositories.initial_repository!().id)
      else
        attrs
      end

    Project.changeset(project, attrs)
  end

  def list_project_items(project_id) when is_integer(project_id) do
    project = get_project!(project_id)
    list_project_items(project)
  end

  def list_project_items(%Project{id: project_id, repository_id: repository_id}) do
    ProjectItem
    |> where(project_id: ^project_id, repository_id: ^repository_id)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  def get_project_item!(id) do
    repository = Repositories.initial_repository!()
    Repo.get_by!(ProjectItem, id: id, repository_id: repository.id)
  end

  def get_project_item!(%Project{id: project_id, repository_id: repository_id}, id) do
    Repo.get_by!(ProjectItem,
      id: id,
      project_id: project_id,
      repository_id: repository_id
    )
  end

  def get_project_item_by_owner!(username, project_number, item_id) do
    repository_id = Repositories.initial_repository!().id

    Repo.one!(
      from item in ProjectItem,
        join: project in Project,
        on:
          project.id == item.project_id and project.repository_id == item.repository_id and
            project.number == ^project_number,
        where:
          item.repository_id == ^repository_id and item.id == ^item_id and
            fragment("lower(?)", project.owner) == ^String.downcase(username)
    )
  end

  def create_project_item(attrs, project, actor \\ nil)

  def create_project_item(attrs, project_id, actor)
      when is_integer(project_id) do
    project = get_project!(project_id)
    create_project_item(attrs, project, actor)
  end

  def create_project_item(attrs, %Project{} = project, actor)
      when is_nil(actor) or is_struct(actor, User) do
    attrs = to_string_map(attrs)
    values = Map.get(attrs, "values", %{})

    result =
      case Map.get(attrs, "issue_number") do
        nil ->
          %ProjectItem{}
          |> ProjectItem.changeset(%{
            "project_id" => project.id,
            "repository_id" => project.repository_id,
            "values" => values
          })
          |> Ecto.Changeset.apply_action(:insert)

        issue_number ->
          issue =
            Repo.get_by!(Issue,
              repository_id: project.repository_id,
              number: issue_number
            )

          %ProjectItem{}
          |> ProjectItem.changeset(%{
            "project_id" => project.id,
            "issue_id" => issue.id,
            "repository_id" => project.repository_id,
            "values" => values
          })
          |> Repo.insert()
      end

    case result do
      {:ok, item} ->
        Analytics.capture("project_item_added", actor_distinct_id(actor), %{
          "project_number" => project.number,
          "has_issue" => match?(%ProjectItem{issue_id: id} when id != nil, item)
        })

        {:ok, item}

      result ->
        result
    end
  end

  def update_project_item(%ProjectItem{} = item, attrs) do
    attrs = to_string_map(attrs)
    values = Map.merge(item.values || %{}, Map.get(attrs, "values", %{}))

    item
    |> ProjectItem.changeset(%{"values" => values})
    |> Repo.update()
  end

  def list_project_fields(project_id) when is_integer(project_id) do
    project = get_project!(project_id)
    list_project_fields(project)
  end

  def list_project_fields(%Project{id: project_id}) do
    ProjectField
    |> where(project_id: ^project_id)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  def create_project_field(attrs) do
    %ProjectField{}
    |> ProjectField.changeset(attrs)
    |> Repo.insert()
  end

  defp next_project_number(repository_id) do
    case Repo.aggregate(
           from(project in Project, where: project.repository_id == ^repository_id),
           :max,
           :number
         ) do
      nil -> 1
      number -> number + 1
    end
  end

  defp number_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == "projects_repository_id_number_index"
    end)
  end

  defp put_owner(attrs, nil), do: attrs

  defp put_owner(attrs, %User{} = owner) do
    attrs
    |> Map.put("owner", owner.github_login)
    |> Map.put("owner_user_id", owner.id)
  end

  defp to_string_map(attrs) do
    for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
  end
end
