defmodule OpenAgents.ProjectItems do
  @moduledoc """
  The ProjectItems context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo

  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories

  @doc """
  Returns the list of project_items.

  ## Examples

      iex> list_project_items()
      [%ProjectItem{}, ...]

  """
  def list_project_items do
    repository_id = Repositories.initial_repository!().id
    Repo.all(from item in ProjectItem, where: item.repository_id == ^repository_id)
  end

  @doc """
  Gets a single project_item.

  Raises `Ecto.NoResultsError` if the Project item does not exist.

  ## Examples

      iex> get_project_item!(123)
      %ProjectItem{}

      iex> get_project_item!(456)
      ** (Ecto.NoResultsError)

  """
  def get_project_item!(id) do
    repository_id = Repositories.initial_repository!().id
    Repo.get_by!(ProjectItem, id: id, repository_id: repository_id)
  end

  @doc """
  Creates a project_item.

  ## Examples

      iex> create_project_item(%{field: value})
      {:ok, %ProjectItem{}}

      iex> create_project_item(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project_item(attrs) do
    attrs = for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
    repository_id = repository_id_for(Map.get(attrs, "project_id"))

    %ProjectItem{}
    |> ProjectItem.changeset(Map.put(attrs, "repository_id", repository_id))
    |> Repo.insert()
  end

  @doc """
  Updates a project_item.

  ## Examples

      iex> update_project_item(project_item, %{field: new_value})
      {:ok, %ProjectItem{}}

      iex> update_project_item(project_item, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project_item(%ProjectItem{} = project_item, attrs) do
    project_item
    |> ProjectItem.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project_item.

  ## Examples

      iex> delete_project_item(project_item)
      {:ok, %ProjectItem{}}

      iex> delete_project_item(project_item)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project_item(%ProjectItem{} = project_item) do
    Repo.delete(project_item)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project_item changes.

  ## Examples

      iex> change_project_item(project_item)
      %Ecto.Changeset{data: %ProjectItem{}}

  """
  def change_project_item(%ProjectItem{} = project_item, attrs \\ %{}) do
    ProjectItem.changeset(project_item, attrs)
  end

  defp repository_id_for(nil), do: Repositories.initial_repository!().id

  defp repository_id_for(project_id) do
    case Repo.get(Project, project_id) do
      %Project{repository_id: repository_id} -> repository_id
      nil -> Repositories.initial_repository!().id
    end
  end
end
