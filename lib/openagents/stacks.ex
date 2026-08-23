defmodule OpenAgents.Stacks do
  @moduledoc """
  Durable pull request stacks.

  A stack is a first-class server-side object: ordered pull request entries
  with stored commit boundaries, structural validation, and health states.
  Branch topology alone stays ambiguous; the stack row is the identity.
  """
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Browse
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks.IdempotencyRequest
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry
  alias OpenAgents.Stacks.StackEvent

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

  @doc "Lists a repository's stacks with active entries, newest first."
  def list(%Repository{id: repository_id}) do
    Stack
    |> where(repository_id: ^repository_id)
    |> order_by(desc: :number)
    |> Repo.all()
    |> Repo.preload(entries: active_entries_query())
  end

  @doc """
  Creates a stack from an API request.

  The request names the trunk ref, the pull request numbers bottom to top,
  and optionally the head OIDs the caller observed. The whole validation
  chain runs inside one metadata transaction with row locks. A retried
  idempotency key replays the original result; the same key with a different
  request fails with `:idempotency_conflict`.
  """
  def create_from_api(%Repository{} = repository, params, %User{} = actor, idempotency_key)
      when is_binary(idempotency_key) do
    with :ok <- authorize(repository, actor),
         {:ok, request} <- parse_create_request(params) do
      request_digest = digest({:create, request})

      run_idempotent(repository, actor, "stack_create", idempotency_key, request_digest, fn ->
        create_stack_rows(repository, request, actor, idempotency_key, request_digest)
      end)
    end
  end

  @doc """
  Appends one pull request to the top of an open stack.

  The new pull request must target the current top head. A caller-supplied
  `expected_stack_version` that mismatches the current version fails with
  `:stale_stack_version`. A successful append bumps the stack version.
  """
  def append_from_api(
        %Repository{} = repository,
        number,
        params,
        %User{} = actor,
        idempotency_key
      )
      when is_integer(number) and is_binary(idempotency_key) do
    with :ok <- authorize(repository, actor),
         {:ok, request} <- parse_append_request(params) do
      request_digest = digest({:append, number, request})

      run_idempotent(repository, actor, "stack_append", idempotency_key, request_digest, fn ->
        append_stack_rows(repository, number, request, actor, idempotency_key, request_digest)
      end)
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

  defp authorize(repository, actor) do
    if Repositories.writable?(repository, actor), do: :ok, else: {:error, :forbidden}
  end

  defp run_idempotent(repository, actor, operation, idempotency_key, request_digest, fun) do
    Repo.transaction(fn ->
      lock_repository_stacks(repository.id)

      case get_idempotency_request(actor.id, operation, idempotency_key) do
        %IdempotencyRequest{request_digest: ^request_digest} = request ->
          {reload_stack(request.stack_id), :replayed}

        %IdempotencyRequest{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          fun.()
      end
    end)
  end

  defp lock_repository_stacks(repository_id) do
    key = "pull_request_stacks:#{repository_id}"
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp get_idempotency_request(user_id, operation, idempotency_key) do
    Repo.one(
      from request in IdempotencyRequest,
        where:
          request.user_id == ^user_id and request.operation == ^operation and
            request.idempotency_key == ^idempotency_key,
        lock: "FOR UPDATE"
    )
  end

  defp reload_stack(stack_id) do
    Stack
    |> Repo.get!(stack_id)
    |> Repo.preload(entries: active_entries_query())
  end

  defp create_stack_rows(repository, request, actor, idempotency_key, request_digest) do
    with {:ok, pull_requests} <- load_pull_requests(repository, request.pull_requests),
         :ok <- validate_structure(repository, pull_requests),
         :ok <- validate_trunk(request.trunk_ref, pull_requests),
         {:ok, trunk_oid} <- resolve_oid(repository, request.trunk_ref),
         {:ok, heads} <- snapshot_heads(repository, pull_requests),
         :ok <- validate_expected_heads(request.expected_heads, pull_requests, heads) do
      stack = insert_stack!(repository, actor, request.trunk_ref)
      entries = insert_entry_rows!(stack, entry_specs(pull_requests, heads, trunk_oid))

      record_event!(stack, "pull_request_stack.created", actor, %{
        "number" => stack.number,
        "trunk_ref" => stack.trunk_ref,
        "trunk_oid" => trunk_oid,
        "entries" => Enum.map(entries, &event_entry/1)
      })

      record_idempotency!(actor, "stack_create", idempotency_key, request_digest, stack.id)
      {%{stack | entries: entries}, :created}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp append_stack_rows(repository, number, request, actor, idempotency_key, request_digest) do
    with {:ok, stack} <- get_stack_for_update(repository, number),
         :ok <- validate_open(stack),
         :ok <- validate_expected_version(request.expected_stack_version, stack),
         {:ok, top, entries} <- top_entry(stack),
         {:ok, [pull_request]} <- load_pull_requests(repository, [request.pull_request]),
         :ok <- validate_append(repository, stack, entries, top, pull_request),
         {:ok, head_oid} <- resolve_oid(repository, pull_request.head_ref),
         :ok <- validate_expected_head(request.expected_head, head_oid),
         {:ok, stack} <- bump_version(stack) do
      entry =
        insert_entry_row!(stack, pull_request, top.position + 1, top.observed_head_oid, head_oid)

      record_event!(stack, "pull_request_stack.appended", actor, %{
        "number" => stack.number,
        "trunk_ref" => stack.trunk_ref,
        "entries" => [event_entry(entry)]
      })

      record_idempotency!(actor, "stack_append", idempotency_key, request_digest, stack.id)
      {%{stack | entries: entries ++ [entry]}, :created}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp parse_create_request(params) do
    with {:ok, trunk_ref} <- ref_param(params, "trunk_ref"),
         {:ok, numbers} <- pull_request_numbers(Map.get(params, "pull_requests")),
         {:ok, expected_heads} <- expected_heads(Map.get(params, "expected_heads"), numbers) do
      {:ok, %{trunk_ref: trunk_ref, pull_requests: numbers, expected_heads: expected_heads}}
    end
  end

  defp parse_append_request(params) do
    with {:ok, number} <- pull_request_number(Map.get(params, "pull_request")),
         {:ok, version} <- expected_version(Map.get(params, "expected_stack_version")),
         {:ok, expected_head} <- optional_oid(Map.get(params, "expected_head")) do
      {:ok,
       %{pull_request: number, expected_stack_version: version, expected_head: expected_head}}
    end
  end

  defp ref_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_request}
    end
  end

  defp pull_request_numbers(numbers) when is_list(numbers) and numbers != [] do
    if Enum.all?(numbers, &(is_integer(&1) and &1 > 0)),
      do: {:ok, numbers},
      else: {:error, :invalid_request}
  end

  defp pull_request_numbers(_other), do: {:error, :invalid_request}

  defp pull_request_number(number) when is_integer(number) and number > 0, do: {:ok, number}
  defp pull_request_number(_other), do: {:error, :invalid_request}

  defp expected_version(nil), do: {:ok, nil}
  defp expected_version(version) when is_integer(version) and version >= 1, do: {:ok, version}
  defp expected_version(_other), do: {:error, :invalid_request}

  defp expected_heads(nil, _numbers), do: {:ok, %{}}

  defp expected_heads(heads, numbers) when is_map(heads) do
    Enum.reduce_while(heads, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {number, ""} <- Integer.parse(to_string(key)),
           true <- number in numbers,
           {:ok, oid} when is_binary(oid) <- optional_oid(value) do
        {:cont, {:ok, Map.put(acc, number, oid)}}
      else
        _invalid -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp expected_heads(_other, _numbers), do: {:error, :invalid_request}

  defp optional_oid(nil), do: {:ok, nil}

  defp optional_oid(value) when is_binary(value) and byte_size(value) in [40, 64] do
    case Base.decode16(value, case: :lower) do
      {:ok, _raw} -> {:ok, value}
      :error -> {:error, :invalid_request}
    end
  end

  defp optional_oid(_other), do: {:error, :invalid_request}

  defp load_pull_requests(%Repository{id: repository_id}, numbers) do
    rows =
      Repo.all(
        from pr in PullRequest,
          join: issue in assoc(pr, :issue),
          where: pr.repository_id == ^repository_id and issue.number in ^numbers,
          preload: [issue: issue],
          lock: "FOR UPDATE"
      )

    by_number = Map.new(rows, &{&1.issue.number, &1})

    numbers
    |> Enum.reduce_while({:ok, []}, fn number, {:ok, acc} ->
      case Map.get(by_number, number) do
        nil -> {:halt, {:error, :pull_request_not_found}}
        pull_request -> {:cont, {:ok, [pull_request | acc]}}
      end
    end)
    |> case do
      {:ok, pull_requests} -> {:ok, Enum.reverse(pull_requests)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_trunk(trunk_ref, [bottom | _rest]) do
    if bottom.base_ref == trunk_ref, do: :ok, else: {:error, :trunk_mismatch}
  end

  defp snapshot_heads(repository, pull_requests) do
    Enum.reduce_while(pull_requests, {:ok, %{}}, fn pull_request, {:ok, acc} ->
      case resolve_oid(repository, pull_request.head_ref) do
        {:ok, oid} -> {:cont, {:ok, Map.put(acc, pull_request.id, oid)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_oid(repository, ref) do
    case Browse.resolve_commit(repository, ref) do
      {:ok, oid} -> {:ok, oid}
      _other -> {:error, :invalid_ref}
    end
  end

  defp validate_expected_heads(expected_heads, pull_requests, heads) do
    by_number = Map.new(pull_requests, &{&1.issue.number, &1})

    Enum.reduce_while(expected_heads, :ok, fn {number, expected}, :ok ->
      pull_request = Map.fetch!(by_number, number)

      if Map.fetch!(heads, pull_request.id) == expected,
        do: {:cont, :ok},
        else: {:halt, {:error, :expected_head_mismatch}}
    end)
  end

  defp validate_expected_head(nil, _head_oid), do: :ok
  defp validate_expected_head(expected, expected), do: :ok
  defp validate_expected_head(_expected, _head_oid), do: {:error, :expected_head_mismatch}

  defp insert_stack!(repository, actor, trunk_ref) do
    %Stack{}
    |> Stack.changeset(%{
      repository_id: repository.id,
      created_by_user_id: actor.id,
      number: next_number(repository.id),
      trunk_ref: trunk_ref
    })
    |> Repo.insert!()
  end

  defp entry_specs(pull_requests, heads, trunk_oid) do
    {specs, _previous_head} =
      pull_requests
      |> Enum.with_index(1)
      |> Enum.map_reduce(trunk_oid, fn {pull_request, position}, boundary ->
        head = Map.fetch!(heads, pull_request.id)
        {{pull_request, position, boundary, head}, head}
      end)

    specs
  end

  defp insert_entry_rows!(stack, specs) do
    Enum.map(specs, fn {pull_request, position, boundary, head} ->
      insert_entry_row!(stack, pull_request, position, boundary, head)
    end)
  end

  defp insert_entry_row!(stack, pull_request, position, boundary, head) do
    entry =
      %StackEntry{}
      |> StackEntry.changeset(%{
        stack_id: stack.id,
        pull_request_id: pull_request.id,
        position: position,
        boundary_oid: boundary,
        observed_head_oid: head
      })
      |> Repo.insert!()

    %{entry | pull_request: pull_request}
  end

  defp event_entry(entry) do
    %{
      "position" => entry.position,
      "pull_request" => entry.pull_request.issue.number,
      "boundary_oid" => entry.boundary_oid,
      "observed_head_oid" => entry.observed_head_oid
    }
  end

  defp record_event!(stack, event_type, actor, payload) do
    %StackEvent{}
    |> StackEvent.changeset(%{
      stack_id: stack.id,
      actor_user_id: actor.id,
      event_type: event_type,
      stack_version: stack.version,
      payload: payload
    })
    |> Repo.insert!()
  end

  defp record_idempotency!(actor, operation, idempotency_key, request_digest, stack_id) do
    %IdempotencyRequest{}
    |> IdempotencyRequest.changeset(
      actor.id,
      operation,
      idempotency_key,
      request_digest,
      stack_id
    )
    |> Repo.insert!()
  end

  defp get_stack_for_update(%Repository{id: repository_id}, number) do
    case Repo.one(
           from stack in Stack,
             where: stack.repository_id == ^repository_id and stack.number == ^number,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :stack_not_found}
      stack -> {:ok, stack}
    end
  end

  defp validate_open(%Stack{state: "open"}), do: :ok
  defp validate_open(%Stack{}), do: {:error, :stack_not_open}

  defp validate_expected_version(nil, _stack), do: :ok
  defp validate_expected_version(version, %Stack{version: version}), do: :ok
  defp validate_expected_version(_version, %Stack{}), do: {:error, :stale_stack_version}

  defp top_entry(stack) do
    case active_entries(stack) do
      [] -> {:error, :empty_stack}
      entries -> {:ok, List.last(entries), entries}
    end
  end

  defp validate_append(repository, stack, entries, top, pull_request) do
    branches = [stack.trunk_ref | Enum.map(entries, & &1.pull_request.head_ref)]

    cond do
      pull_request.head_repository_id != repository.id ->
        {:error, :cross_repository_head}

      pull_request.state != "open" ->
        {:error, :pull_request_not_open}

      pull_request.head_ref in branches ->
        {:error, :duplicate_branch}

      pull_request.base_ref != top.pull_request.head_ref ->
        {:error, :not_stack_top}

      not is_nil(active_entry_for_pull_request(pull_request)) ->
        {:error, :already_stacked}

      true ->
        :ok
    end
  end

  defp bump_version(%Stack{id: id, version: version}) do
    {count, updated} =
      Repo.update_all(
        from(stack in Stack,
          where: stack.id == ^id and stack.version == ^version and stack.state == "open",
          select: stack
        ),
        set: [version: version + 1, updated_at: DateTime.utc_now()]
      )

    case {count, updated} do
      {1, [stack]} -> {:ok, stack}
      {0, _} -> {:error, :stale_stack_version}
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
