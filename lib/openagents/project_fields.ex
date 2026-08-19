defmodule OpenAgents.ProjectFields do
  @moduledoc """
  The ProjectFields context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo

  alias OpenAgents.ProjectFields.ProjectField

  @doc """
  Returns the list of project_fields.

  ## Examples

      iex> list_project_fields()
      [%ProjectField{}, ...]

  """
  def list_project_fields do
    Repo.all(ProjectField)
  end

  @doc """
  Gets a single project_field.

  Raises `Ecto.NoResultsError` if the Project field does not exist.

  ## Examples

      iex> get_project_field!(123)
      %ProjectField{}

      iex> get_project_field!(456)
      ** (Ecto.NoResultsError)

  """
  def get_project_field!(id), do: Repo.get!(ProjectField, id)

  @doc """
  Creates a project_field.

  ## Examples

      iex> create_project_field(%{field: value})
      {:ok, %ProjectField{}}

      iex> create_project_field(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_project_field(attrs) do
    %ProjectField{}
    |> ProjectField.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a project_field.

  ## Examples

      iex> update_project_field(project_field, %{field: new_value})
      {:ok, %ProjectField{}}

      iex> update_project_field(project_field, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_project_field(%ProjectField{} = project_field, attrs) do
    project_field
    |> ProjectField.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project_field.

  ## Examples

      iex> delete_project_field(project_field)
      {:ok, %ProjectField{}}

      iex> delete_project_field(project_field)
      {:error, %Ecto.Changeset{}}

  """
  def delete_project_field(%ProjectField{} = project_field) do
    Repo.delete(project_field)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking project_field changes.

  ## Examples

      iex> change_project_field(project_field)
      %Ecto.Changeset{data: %ProjectField{}}

  """
  def change_project_field(%ProjectField{} = project_field, attrs \\ %{}) do
    ProjectField.changeset(project_field, attrs)
  end
end
