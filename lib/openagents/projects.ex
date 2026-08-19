defmodule OpenAgents.Projects do
  @moduledoc """
  The Projects context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo

  alias OpenAgents.Issues.Issue
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project

  @doc """
  Returns the list of projects.

  ## Examples

      iex> list_projects()
      [%Project{}, ...]

  """
  def list_projects do
    Repo.all(Project)
  end

  @doc """
  Gets a single project.

  Raises `Ecto.NoResultsError` if the Project does not exist.

  ## Examples

      iex> get_project!(123)
      %Project{}

      iex> get_project!(456)
      ** (Ecto.NoResultsError)

  """
  def get_project!(id), do: Repo.get!(Project, id)

  def get_project_by_number!(number) when is_integer(number),
    do: Repo.get_by!(Project, number: number)

  @doc """
  Creates a project.

  ## Examples

      iex> create_project(%{field: value})
      {:ok, %Project{}}

      iex> create_project(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project(attrs \\ %{}) do
    number = next_project_number()
    normalized = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    %Project{}
    |> Project.changeset(Map.put_new(normalized, "number", number))
    |> Repo.insert()
  end

  def list_project_items(project_id) do
    ProjectItem
    |> where(project_id: ^project_id)
    |> Repo.all()
  end

  def get_project_item!(id), do: Repo.get!(ProjectItem, id)

  def create_project_item(%{issue_number: issue_number} = attrs, project_id) do
    issue = Repo.get_by!(Issue, number: issue_number)
    values = attrs["values"] || %{}

    %ProjectItem{}
    |> ProjectItem.changeset(%{
      "project_id" => project_id,
      "issue_id" => issue.id,
      "values" => values
    })
    |> Repo.insert()
  end

  def create_project_item(attrs, project_id) do
    attrs =
      for {k, v} <- attrs, into: %{} do
        {to_string(k), v}
      end

    issue_number = Map.get(attrs, "issue_number")
    issue = Repo.get_by!(Issue, number: issue_number)

    %ProjectItem{}
    |> ProjectItem.changeset(%{
      "project_id" => project_id,
      "issue_id" => issue.id,
      "values" => Map.get(attrs, "values", %{})
    })
    |> Repo.insert()
  end

  def update_project_item(%ProjectItem{} = item, attrs) do
    attrs =
      for {k, v} <- attrs, into: %{} do
        {to_string(k), v}
      end

    values = Map.merge(item.values || %{}, Map.get(attrs, "values", %{}))

    item
    |> ProjectItem.changeset(%{"values" => values})
    |> Repo.update()
  end

  def list_project_fields(project_id) do
    ProjectField
    |> where(project_id: ^project_id)
    |> Repo.all()
  end

  def create_project_field(attrs) do
    %ProjectField{}
    |> ProjectField.changeset(attrs)
    |> Repo.insert()
  end

  defp next_project_number do
    case Repo.aggregate(Project, :max, :number) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Updates a project.

  ## Examples

      iex> update_project(project, %{field: new_value})
      {:ok, %Project{}}

      iex> update_project(project, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project.

  ## Examples

      iex> delete_project(project)
      {:ok, %Project{}}

      iex> delete_project(project)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project changes.

  ## Examples

      iex> change_project(project)
      %Ecto.Changeset{data: %Project{}}

  """
  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end
end
