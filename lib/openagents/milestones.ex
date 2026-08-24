defmodule OpenAgents.Milestones do
  @moduledoc """
  The Milestones context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  alias OpenAgents.Milestones.Milestone

  @doc """
  Subscribes the caller to one repository's milestones.

  The message is `{:milestones_changed, repository_id}` and carries nothing
  else, so a subscriber re-reads through its own visibility and authorization
  predicates.

  It says the milestone set moved, not that the issue counts beside it did.
  Those hang off issue rows and arrive on the issue topic, so a page showing
  both subscribes to both.
  """
  def subscribe_milestones(repository_id) when is_binary(repository_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, milestones_topic(repository_id))

  @doc """
  Announces that one repository's milestones moved.

  Called after the owning write commits, never inside it: a subscriber re-reads
  the moment it hears, and an announcement from inside an open transaction
  hands it the repository as it was.
  """
  def broadcast_milestones(repository_id) when is_binary(repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      milestones_topic(repository_id),
      {:milestones_changed, repository_id}
    )
  end

  defp milestones_topic(repository_id), do: "milestones:" <> repository_id

  @doc """
  Returns the list of milestones.

  ## Examples

      iex> list_milestones()
      [%Milestone{}, ...]

  """
  def list_milestones(%Repository{id: repository_id}) do
    Milestone
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :number)
    |> with_issue_counts()
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
  def get_milestone!(%Repository{id: repository_id}, id) do
    Milestone
    |> where(id: ^id, repository_id: ^repository_id)
    |> with_issue_counts()
    |> Repo.one!()
  end

  def get_milestone_by_number!(%Repository{id: repository_id}, number) when is_integer(number) do
    Milestone
    |> where(repository_id: ^repository_id, number: ^number)
    |> with_issue_counts()
    |> Repo.one!()
  end

  @doc """
  Creates a milestone.

  ## Examples

      iex> create_milestone(%{field: value})
      {:ok, %Milestone{}}

      iex> create_milestone(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_milestone(%Repository{} = repository, attrs, actor \\ nil)
      when is_nil(actor) or is_struct(actor, User) do
    normalized = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
    explicit_number? = Map.has_key?(normalized, "number")

    create_milestone_with_number(repository, normalized, explicit_number?, actor, 20)
  end

  defp create_milestone_with_number(
         repository,
         normalized,
         explicit_number?,
         actor,
         attempts_remaining
       ) do
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
            actor,
            attempts_remaining - 1
          )
        else
          {:error, changeset}
        end

      {:ok, milestone} ->
        Analytics.capture("milestone_created", actor_distinct_id(actor), %{
          "owner" => repository.owner,
          "repo" => repository.name
        })

        broadcast_milestones(repository.id)
        {:ok, milestone}

      result ->
        result
    end
  end

  defp actor_distinct_id(nil), do: Analytics.system_distinct_id("api")
  defp actor_distinct_id(%User{} = actor), do: Analytics.distinct_id(actor)

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

    case milestone |> Milestone.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast_milestones(updated.repository_id)

        {:ok,
         get_milestone!(
           %Repository{id: updated.repository_id},
           updated.id
         )}

      result ->
        result
    end
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
    case Repo.delete(milestone) do
      {:ok, deleted} ->
        broadcast_milestones(deleted.repository_id)
        {:ok, deleted}

      result ->
        result
    end
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

  defp with_issue_counts(query) do
    from milestone in query,
      left_join: issue in Issue,
      on:
        issue.milestone_id == milestone.id and
          issue.repository_id == milestone.repository_id,
      group_by: milestone.id,
      select_merge: %{
        open_issues: filter(count(issue.id), issue.state == "open"),
        closed_issues: filter(count(issue.id), issue.state == "closed")
      }
  end
end
