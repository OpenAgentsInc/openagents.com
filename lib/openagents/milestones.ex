defmodule OpenAgents.Milestones do
  @moduledoc """
  The Milestones context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo

  alias OpenAgents.Milestones.Milestone

  @doc """
  Returns the list of milestones.

  ## Examples

      iex> list_milestones()
      [%Milestone{}, ...]

  """
  def list_milestones do
    Repo.all(Milestone)
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
  def get_milestone!(id), do: Repo.get!(Milestone, id)

  def get_milestone_by_number!(number) when is_integer(number),
    do: Repo.get_by!(Milestone, number: number)

  @doc """
  Creates a milestone.

  ## Examples

      iex> create_milestone(%{field: value})
      {:ok, %Milestone{}}

      iex> create_milestone(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_milestone(attrs \\ %{}) do
    number = next_milestone_number()
    normalized = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    %Milestone{}
    |> Milestone.changeset(Map.put_new(normalized, "number", number))
    |> Repo.insert()
  end

  defp next_milestone_number do
    case Repo.aggregate(Milestone, :max, :number) do
      nil -> 1
      n -> n + 1
    end
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
