defmodule OpenAgents.Stacks do
  @moduledoc """
  Durable pull request stacks.

  A stack is a first-class server-side object: ordered pull request entries
  with stored commit boundaries, structural validation, and health states.
  Branch topology alone stays ambiguous; the stack row is the identity.
  """
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry

  @doc """
  Creates a stack from pull requests ordered bottom to top.

  The bottom pull request's base branch becomes the stack trunk. Every later
  pull request must target the preceding pull request's head branch. All pull
  requests must be open, belong to `repository`, carry same-repository heads,
  and not already belong to an active stack.
  """
  def create(%Repository{} = repository, pull_requests, %User{} = actor)
      when is_list(pull_requests) do
    with :ok <- validate_structure(repository, pull_requests) do
      insert_with_number(repository, pull_requests, actor, 20)
    end
  end

  def get_by_number!(%Repository{id: repository_id}, number) when is_integer(number) do
    Stack
    |> Repo.get_by!(repository_id: repository_id, number: number)
    |> Repo.preload(entries: active_entries_query())
  end

  @doc "Returns the active entries of a stack ordered by position."
  def active_entries(%Stack{id: stack_id}) do
    Repo.all(from entry in active_entries_query(), where: entry.stack_id == ^stack_id)
  end

  @doc "Returns the active stack entry for a pull request, or `nil`."
  def active_entry_for_pull_request(%PullRequest{id: pull_request_id}) do
    Repo.one(
      from entry in StackEntry,
        where: entry.pull_request_id == ^pull_request_id and is_nil(entry.removed_at)
    )
  end

  @doc """
  Confirms a generic base edit may touch a pull request.

  While a pull request is an active stack member, its base branch belongs to
  the stack service; a generic edit fails with `:stack_managed_base`.
  """
  def ensure_base_editable(%PullRequest{} = pull_request) do
    case active_entry_for_pull_request(pull_request) do
      nil -> :ok
      %StackEntry{} -> {:error, :stack_managed_base}
    end
  end

  @doc """
  Records an observed health state without changing the stack state.

  Health describes the current Git graph; state describes the stack's
  lifecycle. A stale graph never dissolves a stack.
  """
  def set_health(%Stack{} = stack, health) do
    stack
    |> Stack.changeset(%{health: health})
    |> Repo.update()
  end

  @doc "Marks an open stack completed, expecting the caller's version."
  def complete(%Stack{} = stack), do: transition(stack, "completed")

  @doc "Marks an open stack dissolved, expecting the caller's version."
  def dissolve(%Stack{} = stack), do: transition(stack, "dissolved")

  defp transition(%Stack{id: id, version: version, state: "open"}, state) do
    now = DateTime.utc_now()

    {count, updated} =
      Repo.update_all(
        from(stack in Stack,
          where: stack.id == ^id and stack.version == ^version and stack.state == "open",
          select: stack
        ),
        set: [state: state, version: version + 1, updated_at: now]
      )

    case {count, updated} do
      {1, [stack]} -> {:ok, stack}
      {0, _} -> {:error, :stale_stack_version}
    end
  end

  defp transition(%Stack{}, _state), do: {:error, :stack_not_open}

  defp active_entries_query do
    from entry in StackEntry,
      where: is_nil(entry.removed_at),
      order_by: [asc: entry.position],
      preload: [pull_request: :issue]
  end

  defp validate_structure(_repository, []), do: {:error, :empty_stack}

  defp validate_structure(%Repository{id: repository_id}, pull_requests) do
    cond do
      Enum.any?(pull_requests, &(&1.repository_id != repository_id)) ->
        {:error, :repository_mismatch}

      Enum.any?(pull_requests, &(&1.head_repository_id != repository_id)) ->
        {:error, :cross_repository_head}

      Enum.any?(pull_requests, &(&1.state != "open")) ->
        {:error, :pull_request_not_open}

      duplicate?(Enum.map(pull_requests, & &1.id)) ->
        {:error, :duplicate_pull_request}

      duplicate?(branches(pull_requests)) ->
        {:error, :duplicate_branch}

      not chained?(pull_requests) ->
        {:error, :broken_base_chain}

      stacked_already?(pull_requests) ->
        {:error, :already_stacked}

      true ->
        :ok
    end
  end

  defp branches([bottom | _rest] = pull_requests) do
    [bottom.base_ref | Enum.map(pull_requests, & &1.head_ref)]
  end

  defp duplicate?(values), do: Enum.uniq(values) != values

  defp chained?(pull_requests) do
    pull_requests
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [lower, upper] -> upper.base_ref == lower.head_ref end)
  end

  defp stacked_already?(pull_requests) do
    ids = Enum.map(pull_requests, & &1.id)

    Repo.exists?(
      from entry in StackEntry,
        where: entry.pull_request_id in ^ids and is_nil(entry.removed_at)
    )
  end

  defp insert_with_number(_repository, _pull_requests, _actor, 0), do: {:error, :number_conflict}

  defp insert_with_number(repository, pull_requests, actor, attempts_remaining) do
    [bottom | _rest] = pull_requests

    result =
      Repo.transaction(fn ->
        number = next_number(repository.id)

        with {:ok, stack} <-
               %Stack{}
               |> Stack.changeset(%{
                 repository_id: repository.id,
                 created_by_user_id: actor.id,
                 number: number,
                 trunk_ref: bottom.base_ref
               })
               |> Repo.insert(),
             {:ok, entries} <- insert_entries(stack, pull_requests) do
          %{stack | entries: entries}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:error, changeset} when attempts_remaining > 1 ->
        if number_conflict?(changeset) do
          insert_with_number(repository, pull_requests, actor, attempts_remaining - 1)
        else
          {:error, changeset}
        end

      other ->
        other
    end
  end

  defp insert_entries(stack, pull_requests) do
    pull_requests
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {pull_request, position}, {:ok, entries} ->
      boundary =
        case entries do
          [] -> pull_request.base_sha
          [previous_entry | _] -> previous_entry.observed_head_oid
        end

      case %StackEntry{}
           |> StackEntry.changeset(%{
             stack_id: stack.id,
             pull_request_id: pull_request.id,
             position: position,
             boundary_oid: boundary,
             observed_head_oid: pull_request.head_sha
           })
           |> Repo.insert() do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp next_number(repository_id) do
    max =
      Repo.one(
        from stack in Stack,
          where: stack.repository_id == ^repository_id,
          select: max(stack.number)
      )

    (max || 0) + 1
  end

  defp number_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, meta}} ->
      meta[:constraint] == :unique and
        meta[:constraint_name] == "pull_request_stacks_repository_id_number_index"
    end)
  end

  defp number_conflict?(_other), do: false
end
