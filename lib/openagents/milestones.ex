defmodule OpenAgents.Milestones do
  @moduledoc """
  The Milestones context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  alias OpenAgents.Milestones.Milestone

  @doc """
  Returns the list of milestones.

  ## Examples

      iex> list_milestones()
      [%Milestone{}, ...]

  """
  def list_milestones, do: list_milestones(Repositories.initial_repository!())

  def list_milestones(%Repository{id: repository_id}) do
    Milestone
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :number)
    |> Repo.all()
  end

  @doc """
  Gets a single milestone.

  Raises `Ecto.NoResultsError` if the Milestone does not exist.

  ## Examples

      iex> get_milestone!(123)
      %Milestone{}

      iex> get_milestone!(456)
      ** (Ecto.NoResultsError)

  """
  def get_milestone!(id), do: get_milestone!(Repositories.initial_repository!(), id)

  def get_milestone!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Milestone, id: id, repository_id: repository_id)
  end

  def get_milestone_by_number!(number) when is_integer(number),
    do: get_milestone_by_number!(Repositories.initial_repository!(), number)

  def get_milestone_by_number!(%Repository{id: repository_id}, number) when is_integer(number),
    do: Repo.get_by!(Milestone, repository_id: repository_id, number: number)

  def get_milestone_by_path!(owner, repository_name, number) when is_integer(number) do
    Repo.one!(
      from milestone in Milestone,
        join: repository in Repository,
        on: repository.id == milestone.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and milestone.number == ^number
    )
  end

  @doc """
  Creates a milestone.

  ## Examples

      iex> create_milestone(%{field: value})
      {:ok, %Milestone{}}

      iex> create_milestone(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_milestone(attrs \\ %{}),
    do: create_milestone(Repositories.initial_repository!(), attrs)

  def create_milestone(%Repository{} = repository, attrs) do
    normalized = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
    explicit_number? = Map.has_key?(normalized, "number")
    create_milestone_with_number(repository, normalized, explicit_number?, 20)
  end

  defp create_milestone_with_number(repository, normalized, explicit_number?, attempts_remaining) do
    number = next_milestone_number(repository.id)

    %Milestone{}
    |> Milestone.changeset(
      normalized
      |> Map.put_new("number", number)
      |> Map.put("repository_id", repository.id)
    )
    |> Repo.insert()
    |> case do
      {:error, changeset} when not explicit_number? and attempts_remaining > 1 ->
        if number_conflict?(changeset) do
          create_milestone_with_number(
            repository,
            normalized,
            explicit_number?,
            attempts_remaining - 1
          )
        else
          {:error, changeset}
        end

      result ->
        result
    end
  end

  defp next_milestone_number(repository_id) do
    case Repo.aggregate(
           from(m in Milestone, where: m.repository_id == ^repository_id),
           :max,
           :number
         ) do
      nil -> 1
      n -> n + 1
    end
  end

  defp number_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == "milestones_repository_id_number_index"
    end)
  end

  @doc """
  Updates a milestone.

  ## Examples

      iex> update_milestone(milestone, %{field: new_value})
      {:ok, %Milestone{}}

      iex> update_milestone(milestone, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_milestone(%Milestone{} = milestone, attrs) do
    attrs = Map.drop(attrs, [:repository_id, "repository_id", :number, "number"])

    milestone
    |> Milestone.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a milestone.

  ## Examples

      iex> delete_milestone(milestone)
      {:ok, %Milestone{}}

      iex> delete_milestone(milestone)
      {:error, %Ecto.Changeset{}}

  """
  def delete_milestone(%Milestone{} = milestone) do
    Repo.delete(milestone)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking milestone changes.

  ## Examples

      iex> change_milestone(milestone)
      %Ecto.Changeset{data: %Milestone{}}

  """
  def change_milestone(%Milestone{} = milestone, attrs \\ %{}) do
    Milestone.changeset(milestone, attrs)
  end
end
