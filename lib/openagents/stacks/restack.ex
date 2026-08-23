defmodule OpenAgents.Stacks.Restack do
  @moduledoc """
  Cascading server-side stack rebase.

  One durable operation walks the stack bottom to top: it verifies each live
  branch still equals the stored observed head, replays only the commits
  after the stored boundary onto the new parent, and plans one ref update
  per branch. New commits build under hidden internal refs first; every
  public branch then moves through one atomic compare-and-swap batch, so a
  concurrent push rejects the whole batch and the user's branch survives.

  A conflict pauses the operation in `waiting_for_conflict_resolution` with
  a persisted workspace — old boundary, old head, proposed parent, in-flight
  commit, conflict paths, and the steps that already succeeded — so continue
  resumes exactly where the replay stopped and abort rolls back without any
  public ref having moved.

  Replayed commits are unsigned and carry the forge committer identity while
  preserving each original author and message (`docs/stacked-prs.md` section
  12.5); repositories that require author signatures rebase locally instead.
  """
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.GitPlane
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks.Operation
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry
  alias OpenAgents.Stacks.StackEvent

  @doc """
  Requests a rebase of an open stack onto its current trunk tip.

  The request inserts one durable `Operation` row in state `pending`; a
  worker claims and executes it. A retried idempotency key replays the
  original operation; the same key with a different request fails with
  `:idempotency_conflict`. Only one operation may be active per stack.
  """
  def request_from_api(%Repository{} = repository, number, params, %User{} = actor, key)
      when is_integer(number) and is_binary(key) do
    with :ok <- authorize(repository, actor),
         {:ok, request} <- parse_rebase_request(params) do
      Repo.transaction(fn ->
        lock_repository_stacks(repository.id)

        with {:ok, stack} <- get_stack_for_update(repository, number),
             :ok <- validate_open(stack),
             {:ok, replay} <- check_idempotency(stack, key, request),
             :ok <- ensure_no_active_operation(stack, replay),
             :ok <- validate_expected_version(request["expected_stack_version"], stack) do
          case replay do
            %Operation{} = operation ->
              {operation, :replayed}

            nil ->
              operation = insert_operation!(stack, actor, key, request)
              set_health!(stack, "operation_in_progress")
              {operation, :created}
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Fetches one operation of a stack, scoped by repository and stack number."
  def get_operation(%Repository{} = repository, number, operation_id) do
    case Ecto.UUID.cast(operation_id) do
      {:ok, operation_id} -> get_valid_operation(repository, number, operation_id)
      :error -> {:error, :operation_not_found}
    end
  end

  defp get_valid_operation(repository, number, operation_id) do
    operation =
      Repo.one(
        from operation in Operation,
          join: stack in assoc(operation, :stack),
          where:
            operation.id == ^operation_id and stack.number == ^number and
              stack.repository_id == ^repository.id
      )

    case operation do
      nil -> {:error, :operation_not_found}
      %Operation{} -> {:ok, operation}
    end
  end

  @doc """
  Resumes a paused rebase with a caller-supplied resolution commit.

  The resolution commit must already exist in the repository and its parent
  must be the persisted `onto` — the tip the in-flight commit failed to
  replay onto. The operation returns to `pending` and the worker resumes
  from the persisted workspace; it re-verifies every branch head before
  applying anything.
  """
  def continue_from_api(%Repository{} = repository, number, operation_id, params, %User{} = actor) do
    with :ok <- authorize(repository, actor),
         {:ok, resolution} <- required_oid(params, "resolution_oid") do
      Repo.transaction(fn ->
        with {:ok, operation} <- get_operation_for_update(repository, number, operation_id),
             :ok <- validate_waiting(operation),
             :ok <- validate_resolution(repository, operation, resolution) do
          conflict = Map.put(operation.conflict, "resolution_oid", resolution)

          operation
          |> Operation.transition_changeset(%{
            state: "pending",
            conflict: conflict,
            retry_at: DateTime.utc_now()
          })
          |> Repo.update!()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Aborts a pending or paused operation.

  No public ref has moved before an operation succeeds, so abort only marks
  the row `cancelled` and restores the stack health observed at request
  time (or `conflicted` when the pause proved a conflict exists).
  """
  def abort_from_api(%Repository{} = repository, number, operation_id, %User{} = actor) do
    with :ok <- authorize(repository, actor) do
      Repo.transaction(fn ->
        with {:ok, operation} <- get_operation_for_update(repository, number, operation_id),
             :ok <- validate_abortable(operation) do
          stack = Repo.one!(from stack in Stack, where: stack.id == ^operation.stack_id)
          set_health!(stack, abort_health(operation))

          operation
          |> Operation.transition_changeset(%{
            state: "cancelled",
            completed_at: DateTime.utc_now()
          })
          |> Repo.update!()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Executes one claimed rebase operation to a terminal or paused state.

  The caller (the operation worker) has already marked the row `running`.
  Every state this function persists is recoverable: a crash before the
  final metadata transaction leaves either nothing moved or the paused
  conflict row, and a stale-leased `running` row re-executes from the
  persisted request and workspace.
  """
  def execute(%Operation{kind: "rebase"} = operation) do
    stack = load_stack(operation.stack_id)
    repository = Repo.one!(from r in Repository, where: r.id == ^stack.repository_id)

    with :ok <- validate_executable(operation, stack),
         {:ok, trunk_tip} <- resolve_trunk(repository, stack),
         operation = record_snapshot!(operation, stack, trunk_tip),
         {:ok, steps} <- plan(operation, repository, stack, trunk_tip),
         {:ok, applied} <- apply_refs(operation, repository, steps) do
      finish(operation, stack, trunk_tip, steps, applied)
    else
      {:pause, conflict} -> pause(operation, conflict)
      {:error, reason} -> fail(operation, stack, reason)
    end
  end

  # The snapshot pins what the operation saw before touching anything, so a
  # recovered worker can compare the live repository against the recorded
  # starting point. The first execution records it; a resumed one keeps it.
  defp record_snapshot!(%Operation{snapshot: nil} = operation, stack, trunk_tip) do
    snapshot = %{
      "trunk_oid" => trunk_tip,
      "stack_version" => stack.version,
      "entries" =>
        Enum.map(stack.entries, fn entry ->
          %{
            "position" => entry.position,
            "ref" => "refs/heads/" <> entry.pull_request.head_ref,
            "boundary_oid" => entry.boundary_oid,
            "observed_head_oid" => entry.observed_head_oid
          }
        end)
    }

    operation
    |> Operation.transition_changeset(%{state: operation.state, snapshot: snapshot})
    |> Repo.update!()
  end

  defp record_snapshot!(%Operation{} = operation, _stack, _trunk_tip), do: operation

  ## Planning

  defp plan(operation, repository, stack, trunk_tip) do
    case operation.conflict do
      %{"resolution_oid" => resolution} = conflict ->
        resume_plan(repository, stack, conflict, resolution)

      _no_resolution ->
        waterfall(repository, stack.entries, trunk_tip, [])
    end
  end

  defp waterfall(_repository, [], _new_parent, steps), do: {:ok, Enum.reverse(steps)}

  defp waterfall(repository, [entry | rest], new_parent, steps) do
    with :ok <- verify_live_head(repository, entry),
         {:ok, step} <- plan_entry(repository, entry, new_parent, steps) do
      waterfall(repository, rest, step.new_head, [step | steps])
    end
  end

  defp plan_entry(_repository, entry, new_parent, _steps)
       when entry.boundary_oid == new_parent do
    {:ok, step(entry, new_parent, entry.observed_head_oid)}
  end

  defp plan_entry(repository, entry, new_parent, steps) do
    case GitPlane.replay(
           repository.storage_key,
           entry.boundary_oid,
           entry.observed_head_oid,
           new_parent
         ) do
      {:ok, %{new_head: new_head}} ->
        {:ok, step(entry, new_parent, new_head)}

      {:conflict, conflict} ->
        {:pause, conflict_workspace(entry, new_parent, conflict, Enum.reverse(steps))}

      {:error, reason} ->
        {:error, {:replay_failed, entry.position, reason}}
    end
  end

  defp step(entry, new_boundary, new_head) do
    %{
      position: entry.position,
      entry_id: entry.id,
      pull_request_id: entry.pull_request_id,
      pull_request_number: entry.pull_request.issue.number,
      ref: "refs/heads/" <> entry.pull_request.head_ref,
      old_head: entry.observed_head_oid,
      old_boundary: entry.boundary_oid,
      new_boundary: new_boundary,
      new_head: new_head
    }
  end

  defp verify_live_head(repository, entry) do
    ref = "refs/heads/" <> entry.pull_request.head_ref

    case GitPlane.resolve_commit(repository.storage_key, ref) do
      {:ok, oid} when oid == entry.observed_head_oid -> :ok
      {:ok, actual} -> {:error, {:head_changed, ref, actual}}
      {:error, _reason} -> {:error, {:missing_ref, ref}}
    end
  end

  defp conflict_workspace(entry, new_parent, conflict, prior_steps) do
    %{
      "position" => entry.position,
      "entry_id" => entry.id,
      "pull_request_number" => entry.pull_request.issue.number,
      "old_boundary" => entry.boundary_oid,
      "old_head" => entry.observed_head_oid,
      "proposed_parent" => new_parent,
      "onto" => conflict.onto,
      "commit" => conflict.commit,
      "paths" => conflict.paths,
      "messages" => conflict.messages,
      "replayed" => Enum.map(conflict.replayed, &%{"old" => &1.old, "new" => &1.new}),
      "steps" => Enum.map(prior_steps, &stringify_step/1)
    }
  end

  defp stringify_step(step) do
    %{
      "position" => step.position,
      "entry_id" => step.entry_id,
      "pull_request_id" => step.pull_request_id,
      "pull_request_number" => step.pull_request_number,
      "ref" => step.ref,
      "old_head" => step.old_head,
      "old_boundary" => step.old_boundary,
      "new_boundary" => step.new_boundary,
      "new_head" => step.new_head
    }
  end

  defp resume_plan(repository, stack, conflict, resolution) do
    position = Map.fetch!(conflict, "position")
    prior_steps = conflict |> Map.fetch!("steps") |> Enum.map(&atomize_step/1)
    entry = Enum.find(stack.entries, &(&1.position == position))
    rest = Enum.filter(stack.entries, &(&1.position > position))

    with :ok <- verify_prior_steps(repository, prior_steps),
         {:ok, entry} <- require_entry(entry, conflict),
         :ok <- verify_live_head(repository, entry),
         {:ok, step} <- resume_entry(repository, entry, conflict, resolution) do
      waterfall(repository, rest, step.new_head, [step | Enum.reverse(prior_steps)])
    end
  end

  defp atomize_step(step) do
    %{
      position: Map.fetch!(step, "position"),
      entry_id: Map.fetch!(step, "entry_id"),
      pull_request_id: Map.fetch!(step, "pull_request_id"),
      pull_request_number: Map.fetch!(step, "pull_request_number"),
      ref: Map.fetch!(step, "ref"),
      old_head: Map.fetch!(step, "old_head"),
      old_boundary: Map.fetch!(step, "old_boundary"),
      new_boundary: Map.fetch!(step, "new_boundary"),
      new_head: Map.fetch!(step, "new_head")
    }
  end

  defp require_entry(nil, conflict),
    do: {:error, {:entry_removed, Map.fetch!(conflict, "position")}}

  defp require_entry(%StackEntry{} = entry, _conflict), do: {:ok, entry}

  defp verify_prior_steps(repository, steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case GitPlane.resolve_commit(repository.storage_key, step.ref) do
        {:ok, oid} when oid == step.old_head -> {:cont, :ok}
        {:ok, actual} -> {:halt, {:error, {:head_changed, step.ref, actual}}}
        {:error, _reason} -> {:halt, {:error, {:missing_ref, step.ref}}}
      end
    end)
  end

  defp resume_entry(repository, entry, conflict, resolution) do
    in_flight = Map.fetch!(conflict, "commit")
    proposed_parent = Map.fetch!(conflict, "proposed_parent")

    case GitPlane.replay(
           repository.storage_key,
           in_flight,
           entry.observed_head_oid,
           resolution
         ) do
      {:ok, %{new_head: new_head}} ->
        {:ok, step(entry, proposed_parent, new_head)}

      {:conflict, next_conflict} ->
        prior_steps = Map.fetch!(conflict, "steps")

        workspace =
          entry
          |> conflict_workspace(proposed_parent, next_conflict, [])
          |> Map.put("steps", prior_steps)

        {:pause, workspace}

      {:error, reason} ->
        {:error, {:replay_failed, entry.position, reason}}
    end
  end

  ## Ref application

  defp apply_refs(operation, repository, steps) do
    changed = Enum.filter(steps, &(&1.new_head != &1.old_head))

    if changed == [] do
      {:ok, %{moved: false}}
    else
      with {:ok, temp_refs} <- retain_new_commits(operation, repository, changed),
           :ok <- move_public_refs(repository, changed, temp_refs) do
        {:ok, %{moved: true}}
      end
    end
  end

  # New commits become reachable (and WAL-persisted) under hidden internal
  # refs before any public branch moves, so a crash between the two batches
  # never strands the planned commits.
  defp retain_new_commits(operation, repository, changed) do
    temp_refs =
      Enum.map(changed, fn step ->
        {:ok, ref} =
          GitPlane.internal_ref([
            "operations",
            operation.id,
            "a#{operation.attempt_count}",
            "p#{step.position}"
          ])

        %{ref: ref, expected_old: :absent, new: step.new_head}
      end)

    case GitPlane.batch_update_refs(repository.storage_key, temp_refs, principal(operation)) do
      {:ok, _result} -> {:ok, temp_refs}
      {:error, reason} -> {:error, {:retention_failed, reason}}
    end
  end

  # One atomic batch: every public branch moves from its verified old head
  # to its replayed head, and the retention refs delete in the same
  # transaction. Any concurrent push fails the expected-old check and
  # rejects the whole batch, preserving the user's branch.
  defp move_public_refs(repository, changed, temp_refs) do
    updates =
      Enum.map(changed, fn step ->
        %{ref: step.ref, expected_old: step.old_head, new: step.new_head}
      end) ++
        Enum.map(temp_refs, fn temp ->
          %{ref: temp.ref, expected_old: temp.new, new: :delete}
        end)

    case GitPlane.batch_update_refs(repository.storage_key, updates, "stack-restack") do
      {:ok, _result} ->
        :ok

      {:error, {:expected_mismatch, ref, actual}} ->
        cleanup_temp_refs(repository, temp_refs)
        {:error, {:head_changed, ref, actual}}

      {:error, reason} ->
        cleanup_temp_refs(repository, temp_refs)
        {:error, {:ref_update_failed, reason}}
    end
  end

  defp cleanup_temp_refs(repository, temp_refs) do
    deletes = Enum.map(temp_refs, &%{ref: &1.ref, expected_old: &1.new, new: :delete})
    _result = GitPlane.batch_update_refs(repository.storage_key, deletes, "stack-restack")
    :ok
  end

  defp principal(operation), do: "stack-operation-" <> operation.id

  ## Terminal transitions

  defp finish(operation, stack, trunk_tip, steps, applied) do
    result =
      Repo.transaction(fn ->
        lock_repository_stacks(stack.repository_id)
        current = Repo.one!(from s in Stack, where: s.id == ^stack.id, lock: "FOR UPDATE")

        if current.version != operation.expected_stack_version do
          Repo.rollback({:version_moved, current.version})
        end

        stack_after = bump_version!(current)

        Enum.each(steps, &apply_step_metadata!/1)
        record_events!(stack_after, operation, trunk_tip, steps)

        operation
        |> Operation.transition_changeset(%{
          state: "succeeded",
          conflict: nil,
          planned_result: %{
            "trunk_oid" => trunk_tip,
            "moved" => applied.moved,
            "steps" => Enum.map(steps, &stringify_step/1)
          },
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, operation} ->
        {:ok, operation}

      {:error, {:version_moved, _version} = reason} when applied.moved ->
        partially_succeed(operation, trunk_tip, steps, reason)

      {:error, reason} ->
        fail(operation, stack, {:metadata_failed, reason})
    end
  end

  # The refs already moved but the stack metadata advanced underneath the
  # operation, so the branch updates stand while the metadata reconciliation
  # is left to the caller.
  defp partially_succeed(operation, trunk_tip, steps, reason) do
    operation =
      operation
      |> Operation.transition_changeset(%{
        state: "partially_succeeded",
        error: error_map(reason),
        planned_result: %{
          "trunk_oid" => trunk_tip,
          "moved" => true,
          "steps" => Enum.map(steps, &stringify_step/1)
        },
        completed_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {:error, operation}
  end

  defp apply_step_metadata!(step) do
    Repo.one!(from entry in StackEntry, where: entry.id == ^step.entry_id, lock: "FOR UPDATE")
    |> StackEntry.changeset(%{
      boundary_oid: step.new_boundary,
      observed_head_oid: step.new_head
    })
    |> Repo.update!()

    {1, _rows} =
      Repo.update_all(
        from(pr in PullRequest, where: pr.id == ^step.pull_request_id),
        set: [head_sha: step.new_head, base_sha: step.new_boundary]
      )

    :ok
  end

  defp record_events!(stack, operation, trunk_tip, steps) do
    changed = Enum.filter(steps, &(&1.new_head != &1.old_head))

    record_event!(stack, operation, "pull_request_stack.rebased", %{
      "operation_id" => operation.id,
      "trunk_oid" => trunk_tip,
      "steps" => Enum.map(steps, &stringify_step/1)
    })

    Enum.each(changed, fn step ->
      record_event!(stack, operation, "pull_request.synchronize", %{
        "operation_id" => operation.id,
        "pull_request" => step.pull_request_number,
        "ref" => step.ref,
        "before" => step.old_head,
        "after" => step.new_head
      })
    end)
  end

  defp record_event!(stack, operation, event_type, payload) do
    %StackEvent{}
    |> StackEvent.changeset(%{
      stack_id: stack.id,
      actor_user_id: operation.created_by_user_id,
      event_type: event_type,
      stack_version: stack.version,
      payload: payload
    })
    |> Repo.insert!()
  end

  defp pause(operation, conflict) do
    {:ok, operation} =
      Repo.transaction(fn ->
        stack = Repo.one!(from s in Stack, where: s.id == ^operation.stack_id, lock: "FOR UPDATE")
        set_health!(stack, "conflicted")

        operation
        |> Operation.transition_changeset(%{
          state: "waiting_for_conflict_resolution",
          conflict: conflict
        })
        |> Repo.update!()
      end)

    {:waiting, operation}
  end

  defp fail(operation, stack, reason) do
    {:ok, operation} =
      Repo.transaction(fn ->
        current = Repo.one!(from s in Stack, where: s.id == ^stack.id, lock: "FOR UPDATE")
        set_health!(current, failure_health(reason))

        operation
        |> Operation.transition_changeset(%{
          state: "failed",
          error: error_map(reason),
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()
      end)

    {:error, operation}
  end

  defp failure_health({:head_changed, _ref, _actual}), do: "head_changed"
  defp failure_health({:missing_ref, _ref}), do: "missing_ref"
  defp failure_health(_reason), do: "needs_rebase"

  defp error_map({:head_changed, ref, actual}),
    do: %{"code" => "head_changed", "ref" => ref, "actual" => stringify_actual(actual)}

  defp error_map({:missing_ref, ref}), do: %{"code" => "missing_ref", "ref" => ref}

  defp error_map({:replay_failed, position, reason}),
    do: %{"code" => "replay_failed", "position" => position, "reason" => inspect(reason)}

  defp error_map({:retention_failed, reason}),
    do: %{"code" => "retention_failed", "reason" => inspect(reason)}

  defp error_map({:ref_update_failed, reason}),
    do: %{"code" => "ref_update_failed", "reason" => inspect(reason)}

  defp error_map({:metadata_failed, reason}),
    do: %{"code" => "metadata_failed", "reason" => inspect(reason)}

  defp error_map({:version_moved, version}),
    do: %{"code" => "version_moved", "stack_version" => version}

  defp error_map(reason) when is_atom(reason), do: %{"code" => Atom.to_string(reason)}
  defp error_map(reason), do: %{"code" => "operation_failed", "reason" => inspect(reason)}

  defp stringify_actual(:absent), do: "absent"
  defp stringify_actual(oid), do: oid

  ## Validation

  defp validate_executable(operation, stack) do
    cond do
      stack.state != "open" -> {:error, :stack_not_open}
      stack.version != operation.expected_stack_version -> {:error, :stale_stack_version}
      stack.entries == [] -> {:error, :empty_stack}
      true -> :ok
    end
  end

  defp resolve_trunk(repository, stack) do
    case GitPlane.resolve_commit(repository.storage_key, "refs/heads/" <> stack.trunk_ref) do
      {:ok, oid} -> {:ok, oid}
      {:error, _reason} -> {:error, {:missing_ref, "refs/heads/" <> stack.trunk_ref}}
    end
  end

  defp authorize(repository, actor) do
    if Repositories.writable?(repository, actor), do: :ok, else: {:error, :forbidden}
  end

  defp parse_rebase_request(params) do
    case Map.get(params, "expected_stack_version") do
      nil ->
        {:ok, %{"expected_stack_version" => nil}}

      version when is_integer(version) and version >= 1 ->
        {:ok, %{"expected_stack_version" => version}}

      _other ->
        {:error, :invalid_request}
    end
  end

  defp required_oid(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and byte_size(value) in [40, 64] ->
        case Base.decode16(value, case: :lower) do
          {:ok, _raw} -> {:ok, value}
          :error -> {:error, :invalid_request}
        end

      _other ->
        {:error, :invalid_request}
    end
  end

  defp check_idempotency(stack, key, request) do
    operation =
      Repo.one(
        from operation in Operation,
          where: operation.stack_id == ^stack.id and operation.idempotency_key == ^key,
          lock: "FOR UPDATE"
      )

    case operation do
      nil ->
        {:ok, nil}

      %Operation{} = operation ->
        if Map.drop(operation.request, ["previous_health"]) == request,
          do: {:ok, operation},
          else: {:error, :idempotency_conflict}
    end
  end

  defp ensure_no_active_operation(_stack, %Operation{}), do: :ok

  defp ensure_no_active_operation(stack, nil) do
    active =
      Repo.exists?(
        from operation in Operation,
          where:
            operation.stack_id == ^stack.id and
              operation.state in ^Operation.active_states()
      )

    if active, do: {:error, :operation_in_progress}, else: :ok
  end

  defp validate_expected_version(nil, _stack), do: :ok
  defp validate_expected_version(version, %Stack{version: version}), do: :ok
  defp validate_expected_version(_version, %Stack{}), do: {:error, :stale_stack_version}

  defp insert_operation!(stack, actor, key, request) do
    %Operation{}
    |> Operation.changeset(%{
      stack_id: stack.id,
      created_by_user_id: actor.id,
      kind: "rebase",
      state: "pending",
      expected_stack_version: request["expected_stack_version"] || stack.version,
      idempotency_key: key,
      request: Map.put(request, "previous_health", stack.health),
      retry_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp get_operation_for_update(repository, number, operation_id) do
    with {:ok, operation} <- get_operation(repository, number, operation_id) do
      {:ok,
       Repo.one!(
         from candidate in Operation,
           where: candidate.id == ^operation.id,
           lock: "FOR UPDATE"
       )}
    end
  end

  defp validate_waiting(%Operation{state: "waiting_for_conflict_resolution"}), do: :ok
  defp validate_waiting(%Operation{}), do: {:error, :operation_not_waiting}

  defp validate_abortable(%Operation{state: state})
       when state in ["pending", "waiting_for_conflict_resolution"],
       do: :ok

  defp validate_abortable(%Operation{}), do: {:error, :operation_not_abortable}

  defp validate_resolution(repository, operation, resolution) do
    onto = Map.fetch!(operation.conflict, "onto")

    with {:ok, _oid} <- resolve_or_error(repository, resolution),
         {:ok, parents} <- parents_of(repository, resolution) do
      if parents == [onto], do: :ok, else: {:error, :resolution_parent_mismatch}
    end
  end

  defp resolve_or_error(repository, oid) do
    case GitPlane.resolve_commit(repository.storage_key, oid) do
      {:ok, full} when full == oid -> {:ok, full}
      {:ok, _other} -> {:error, :resolution_not_found}
      {:error, _reason} -> {:error, :resolution_not_found}
    end
  end

  defp parents_of(repository, oid) do
    case GitPlane.parents(repository.storage_key, oid) do
      {:ok, parents} -> {:ok, parents}
      {:error, _reason} -> {:error, :resolution_not_found}
    end
  end

  defp abort_health(%Operation{state: "waiting_for_conflict_resolution"}), do: "conflicted"

  defp abort_health(%Operation{request: request}),
    do: Map.get(request, "previous_health", "needs_rebase")

  ## Shared helpers

  defp load_stack(stack_id) do
    Stack
    |> Repo.get!(stack_id)
    |> Repo.preload(
      entries:
        from(entry in StackEntry,
          where: is_nil(entry.removed_at),
          order_by: [asc: entry.position],
          preload: [pull_request: :issue]
        )
    )
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

  defp lock_repository_stacks(repository_id) do
    key = "pull_request_stacks:#{repository_id}"
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp set_health!(%Stack{} = stack, health) do
    stack
    |> Stack.changeset(%{health: health})
    |> Repo.update!()
  end

  defp bump_version!(%Stack{id: id, version: version, state: "open"}) do
    {1, [stack]} =
      Repo.update_all(
        from(stack in Stack,
          where: stack.id == ^id and stack.version == ^version and stack.state == "open",
          select: stack
        ),
        set: [version: version + 1, health: "healthy", updated_at: DateTime.utc_now()]
      )

    stack
  end
end
