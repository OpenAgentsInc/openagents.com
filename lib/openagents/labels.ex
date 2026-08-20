defmodule OpenAgents.Labels do
  @moduledoc """
  The Labels context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  alias OpenAgents.Labels.Label

  @doc """
  Returns the list of labels.

  ## Examples

      iex> list_labels()
      [%Label{}, ...]

  """
  def list_labels, do: list_labels(Repositories.initial_repository!())

  def list_labels(%Repository{id: repository_id}) do
    Label
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a single label.

  Raises `Ecto.NoResultsError` if the Label does not exist.

  ## Examples

      iex> get_label!(123)
      %Label{}

      iex> get_label!(456)
      ** (Ecto.NoResultsError)

  """
  def get_label!(id), do: get_label!(Repositories.initial_repository!(), id)

  def get_label!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Label, id: id, repository_id: repository_id)
  end

  def get_label_by_name!(name) when is_binary(name) do
    get_label_by_name!(Repositories.initial_repository!(), name)
  end

  def get_label_by_name!(%Repository{id: repository_id}, name) when is_binary(name) do
    Repo.get_by!(Label, repository_id: repository_id, name: URI.decode(name))
  end

  def get_label_by_path!(owner, repository_name, name) do
    Repo.one!(
      from label in Label,
        join: repository in Repository,
        on: repository.id == label.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and label.name == ^URI.decode(name)
    )
  end

  @doc """
  Creates a label.

  ## Examples

      iex> create_label(%{field: value})
      {:ok, %Label{}}

      iex> create_label(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_label(attrs), do: create_label(Repositories.initial_repository!(), attrs)

  def create_label(%Repository{} = repository, attrs) do
    attrs =
      attrs
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
      |> Map.put("repository_id", repository.id)

    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a label.

  ## Examples

      iex> update_label(label, %{field: new_value})
      {:ok, %Label{}}

      iex> update_label(label, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_label(%Label{} = label, attrs) do
    attrs = Map.drop(attrs, [:repository_id, "repository_id"])

    label
    |> Label.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a label.

  ## Examples

      iex> delete_label(label)
      {:ok, %Label{}}

      iex> delete_label(label)
      {:error, %Ecto.Changeset{}}

  """
  def delete_label(%Label{} = label) do
    Repo.delete(label)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking label changes.

  ## Examples

      iex> change_label(label)
      %Ecto.Changeset{data: %Label{}}

  """
  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end
end
