defmodule OpenAgents.Stacks.Merge do
  @moduledoc """
  Contiguous-prefix stack merge (`docs/stacked-prs.md` sections 13 and
  5.9-5.13).

  Selecting a pull request merges it and every open layer below it in one
  durable operation. Preflight validates everything — the contiguous
  prefix, the ancestry chain, live and expected heads, the stack version —
  before any object builds. The merge result and every upper-layer restack
  then build as unreachable candidate commits, persist under hidden
  retention refs, and land through one batch compare-and-swap that moves
  the trunk and every restacked branch together. Merged lower branches
  stay untouched, so their history survives until callers delete them.

  Git refs and SQL metadata are two durable stores, so the operation
  records its planned result before the refs move and marks the plan
  applied immediately after. A worker that reclaims a crashed operation
  reconciles instead of re-merging: when the live refs already equal the
  plan it only finalizes the metadata, when nothing moved it re-plans, and
  when the refs diverged it marks the operation `partially_succeeded` —
  pull requests whose refs landed stay merged even when a later step
  fails.

  An upper-layer restack conflict fails the operation during planning,
  before any ref moves, with the conflict persisted on the operation;
  resolve it through a stack rebase and retry the merge.
  """
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.GitPlane
  alias OpenAgents.Issues.Issue
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks.Operation
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry
  alias OpenAgents.Stacks.StackEvent

  @merge_methods ~w(merge squash rebase)

  @doc """
  Requests a merge of the contiguous lowest prefix ending at one pull
  request.

  The request names the selected pull request, the merge method, optional
  expected heads per layer, and an optional expected stack version. It
  inserts one durable `Operation` row in state `pending`; a worker claims
  and executes it. A retried idempotency key replays the original
  operation.
  """
  def request_from_api(%Repository{} = repository, number, params, %User{} = actor, key)
      when is_integer(number) and is_binary(key) do
    with :ok <- authorize(repository, actor),
         {:ok, request} <- parse_merge_request(params) do
      Repo.transaction(fn ->
        lock_repository_stacks(repository.id)

        with {:ok, stack} <- get_stack_for_update(repository, number),
             :ok <- validate_open(stack),
             {:ok, replay} <- check_idempotency(stack, key, request),
             :ok <- ensure_no_active_operation(stack, replay),
             :ok <- validate_expected_version(request["expected_stack_version"], stack),
             {:ok, position} <- selected_position(stack, request, replay) do
          case replay do
            %Operation{} = operation ->
              {operation, :replayed}

            nil ->
              operation = insert_operation!(stack, actor, key, request, position)
              set_health!(stack, "operation_in_progress")

              record_event!(stack, operation, "pull_request_stack.merge_started", %{
                "stack_number" => stack.number,
                "operation_id" => operation.id,
                "trunk_ref" => stack.trunk_ref,
                "merge_method" => Map.fetch!(request, "merge_method"),
                "pull_request" => Map.fetch!(request, "pull_request_number"),
                "target_position" => position
              })

              {operation, :created}
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Executes one claimed merge operation to a terminal state.

  The caller (the operation worker) has already marked the row `running`.
  A re-execution after a crash reconciles from the persisted plan instead
  of repeating work.
  """
  def execute(%Operation{kind: "merge"} = operation, opts \\ []) do
    stack = load_stack(operation.stack_id)
    repository = Repo.one!(from r in Repository, where: r.id == ^stack.repository_id)

    case reconcile_state(repository, operation) do
      :fresh ->
        run(operation, repository, stack, opts)

      {:applied, plan} ->
        finalize(operation, stack, plan)

      {:diverged, plan} ->
        partially_succeed(operation, plan, :refs_diverged)
    end
  end

  defp run(operation, repository, stack, opts) do
    with :ok <- validate_executable(operation, stack),
         {:ok, trunk_tip} <- resolve_trunk(repository, stack),
         {:ok, selected, upper} <- split_entries(stack, operation.target_position),
         :ok <- preflight(repository, trunk_tip, selected, upper, operation.request),
         operation = record_snapshot!(operation, stack, trunk_tip, selected),
         {:ok, plan} <- build_plan(operation, repository, stack, trunk_tip, selected, upper),
         operation = record_plan!(operation, plan),
         :ok <- apply_refs(operation, repository, plan),
         operation = mark_refs_applied!(operation),
         :ok <- crash_seam(opts) do
      finalize(operation, stack, plan)
    else
      {:error, reason} -> fail(operation, stack, reason)
    end
  end

  # A test-only fault-injection seam: production callers never pass it, so
  # the merge proceeds straight to finalization.
  defp crash_seam(opts) do
    case Keyword.get(opts, :after_refs) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  ## Reconciliation

  # The planned result is the recovery record: `refs_applied` flips true
  # right after the batch-CAS lands, so a reclaimed operation knows whether
  # the git side already moved.
  defp reconcile_state(_repository, %Operation{planned_result: nil}), do: :fresh

  defp reconcile_state(repository, %Operation{planned_result: plan}) do
    refs = planned_refs(plan)

    cond do
      Enum.all?(refs, fn ref -> live_oid(repository, ref["ref"]) == ref["new"] end) ->
        {:applied, plan}

      not plan_marked_applied?(plan) and
          Enum.all?(refs, fn ref -> live_oid(repository, ref["ref"]) == ref["old"] end) ->
        :fresh

      true ->
        {:diverged, plan}
    end
  end

  defp plan_marked_applied?(plan), do: Map.get(plan, "refs_applied") == true

  defp planned_refs(plan) do
    trunk = %{
      "ref" => Map.fetch!(plan, "trunk_ref"),
      "old" => Map.fetch!(plan, "trunk_old"),
      "new" => Map.fetch!(plan, "trunk_new")
    }

    restacked =
      plan
      |> Map.fetch!("restacked")
      |> Enum.map(fn step ->
        %{
          "ref" => Map.fetch!(step, "ref"),
          "old" => Map.fetch!(step, "old_head"),
          "new" => Map.fetch!(step, "new_head")
        }
      end)

    [trunk | restacked]
  end

  defp live_oid(repository, ref) do
    case GitPlane.resolve_commit(repository.storage_key, ref) do
      {:ok, oid} -> oid
      {:error, _reason} -> :absent
    end
  end

  ## Preflight

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

  defp split_entries(stack, target_position) do
    {selected, upper} = Enum.split_with(stack.entries, &(&1.position <= target_position))

    if selected != [] and Enum.any?(selected, &(&1.position == target_position)) do
      {:ok, selected, upper}
    else
      {:error, :pull_request_not_in_stack}
    end
  end

  # Everything validates before any object builds: the selected prefix must
  # be open, current on the trunk, an unbroken parent chain, and live on
  # the branches the stack recorded — and any caller-supplied expected
  # heads must match.
  defp preflight(repository, trunk_tip, selected, upper, request) do
    entries = selected ++ upper

    with :ok <- validate_selected_open(selected),
         :ok <- validate_chain(trunk_tip, entries),
         :ok <- verify_live_heads(repository, entries) do
      validate_expected_heads(request["expected_heads"], entries)
    end
  end

  defp validate_selected_open(selected) do
    Enum.find_value(selected, :ok, fn entry ->
      if entry.pull_request.state == "open" do
        nil
      else
        {:error, :pull_request_not_open}
      end
    end)
  end

  defp validate_chain(trunk_tip, entries) do
    entries
    |> Enum.reduce_while(trunk_tip, fn entry, expected_boundary ->
      if entry.boundary_oid == expected_boundary do
        {:cont, entry.observed_head_oid}
      else
        {:halt, {:error, :needs_rebase}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _head -> :ok
    end
  end

  defp verify_live_heads(repository, entries) do
    Enum.find_value(entries, :ok, fn entry ->
      ref = "refs/heads/" <> entry.pull_request.head_ref

      case GitPlane.resolve_commit(repository.storage_key, ref) do
        {:ok, oid} when oid == entry.observed_head_oid -> nil
        {:ok, actual} -> {:error, {:head_changed, ref, actual}}
        {:error, _reason} -> {:error, {:missing_ref, ref}}
      end
    end)
  end

  defp validate_expected_heads(nil, _entries), do: :ok

  defp validate_expected_heads(expected, entries) when is_map(expected) do
    by_number = Map.new(entries, &{&1.pull_request.issue.number, &1})

    Enum.find_value(expected, :ok, fn {number_key, oid} ->
      with {:ok, number} <- parse_number_key(number_key),
           %StackEntry{} = entry <- Map.get(by_number, number, :missing) do
        if entry.observed_head_oid == oid, do: nil, else: {:error, :expected_head_mismatch}
      else
        _invalid -> {:error, :expected_head_mismatch}
      end
    end)
  end

  defp parse_number_key(key) when is_integer(key), do: {:ok, key}

  defp parse_number_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  ## Snapshot and plan

  defp record_snapshot!(%Operation{snapshot: nil} = operation, stack, trunk_tip, selected) do
    selected_positions = Enum.map(selected, & &1.position)

    snapshot = %{
      "trunk_oid" => trunk_tip,
      "stack_version" => stack.version,
      "selected_positions" => selected_positions,
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

  defp record_snapshot!(%Operation{} = operation, _stack, _trunk_tip, _selected), do: operation

  defp build_plan(operation, repository, stack, trunk_tip, selected, upper) do
    method = Map.fetch!(operation.request, "merge_method")

    with {:ok, trunk_new, merged} <-
           build_merge_result(repository, stack, trunk_tip, selected, method),
         {:ok, restacked} <- plan_upper_restacks(repository, upper, trunk_new) do
      {:ok,
       %{
         "merge_method" => method,
         "trunk_ref" => "refs/heads/" <> stack.trunk_ref,
         "trunk_old" => trunk_tip,
         "trunk_new" => trunk_new,
         "merged" => merged,
         "restacked" => restacked,
         "refs_applied" => false
       }}
    end
  end

  # One group merge commit: both selected history and the current trunk are
  # parents, and the tree is exactly the selected top head's tree.
  defp build_merge_result(repository, stack, trunk_tip, selected, "merge") do
    top = List.last(selected)
    numbers = Enum.map(selected, & &1.pull_request.issue.number)
    message = merge_message(stack, numbers)

    with {:ok, tree} <- tree_of(repository, top.observed_head_oid),
         {:ok, merge_commit} <-
           commit_tree(repository, tree, [trunk_tip, top.observed_head_oid], message) do
      {:ok, merge_commit, Enum.map(selected, &merged_step(&1, merge_commit))}
    end
  end

  # One squash commit per pull request, chained on the trunk, so each trunk
  # commit diffs to exactly one layer.
  defp build_merge_result(repository, _stack, trunk_tip, selected, "squash") do
    selected
    |> Enum.reduce_while({:ok, trunk_tip, []}, fn entry, {:ok, parent, merged} ->
      issue = entry.pull_request.issue
      message = "#{issue.title} (##{issue.number})"

      with {:ok, tree} <- tree_of(repository, entry.observed_head_oid),
           {:ok, author} <- commit_author(repository, entry.observed_head_oid),
           {:ok, squash} <- commit_tree(repository, tree, [parent], message, author: author) do
        {:cont, {:ok, squash, [merged_step(entry, squash) | merged]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, trunk_new, merged} -> {:ok, trunk_new, Enum.reverse(merged)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Replay every selected layer's unique commits in order; the final tree
  # must equal the selected top head's tree.
  defp build_merge_result(repository, _stack, trunk_tip, selected, "rebase") do
    selected
    |> Enum.reduce_while({:ok, trunk_tip, []}, fn entry, {:ok, parent, merged} ->
      case GitPlane.replay(
             repository.storage_key,
             entry.boundary_oid,
             entry.observed_head_oid,
             parent
           ) do
        {:ok, %{new_head: new_head}} ->
          {:cont, {:ok, new_head, [merged_step(entry, new_head) | merged]}}

        {:conflict, _conflict} ->
          {:halt, {:error, {:replay_failed, entry.position, :conflict}}}

        {:error, reason} ->
          {:halt, {:error, {:replay_failed, entry.position, reason}}}
      end
    end)
    |> case do
      {:ok, trunk_new, merged} ->
        top = List.last(selected)

        with {:ok, result_tree} <- tree_of(repository, trunk_new),
             {:ok, top_tree} <- tree_of(repository, top.observed_head_oid) do
          if result_tree == top_tree,
            do: {:ok, trunk_new, Enum.reverse(merged)},
            else: {:error, :rebase_tree_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merged_step(entry, merge_commit_sha) do
    %{
      "position" => entry.position,
      "entry_id" => entry.id,
      "pull_request_id" => entry.pull_request_id,
      "pull_request_number" => entry.pull_request.issue.number,
      "ref" => "refs/heads/" <> entry.pull_request.head_ref,
      "old_head" => entry.observed_head_oid,
      "merge_commit_sha" => merge_commit_sha
    }
  end

  defp merge_message(stack, numbers) do
    "Merge pull requests #{Enum.map_join(numbers, ", ", &"##{&1}")} (stack #{stack.number})"
  end

  # Layers above the selected prefix restack onto the merge result using
  # their stored boundaries. A conflict here fails the whole operation
  # before any ref moves; the persisted error names the conflicting layer.
  defp plan_upper_restacks(repository, upper, trunk_new) do
    upper
    |> Enum.reduce_while({:ok, trunk_new, []}, fn entry, {:ok, parent, steps} ->
      case GitPlane.replay(
             repository.storage_key,
             entry.boundary_oid,
             entry.observed_head_oid,
             parent
           ) do
        {:ok, %{new_head: new_head}} ->
          step = %{
            "position" => entry.position,
            "entry_id" => entry.id,
            "pull_request_id" => entry.pull_request_id,
            "pull_request_number" => entry.pull_request.issue.number,
            "ref" => "refs/heads/" <> entry.pull_request.head_ref,
            "old_head" => entry.observed_head_oid,
            "old_boundary" => entry.boundary_oid,
            "new_boundary" => parent,
            "new_head" => new_head
          }

          {:cont, {:ok, new_head, [step | steps]}}

        {:conflict, conflict} ->
          {:halt,
           {:error,
            {:upper_restack_conflict,
             %{
               "position" => entry.position,
               "pull_request_number" => entry.pull_request.issue.number,
               "onto" => conflict.onto,
               "commit" => conflict.commit,
               "paths" => conflict.paths,
               "messages" => conflict.messages
             }}}}

        {:error, reason} ->
          {:halt, {:error, {:replay_failed, entry.position, reason}}}
      end
    end)
    |> case do
      {:ok, _parent, steps} -> {:ok, Enum.reverse(steps)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_plan!(operation, plan) do
    operation
    |> Operation.transition_changeset(%{state: operation.state, planned_result: plan})
    |> Repo.update!()
  end

  defp mark_refs_applied!(operation) do
    plan = Map.put(operation.planned_result, "refs_applied", true)

    operation
    |> Operation.transition_changeset(%{state: operation.state, planned_result: plan})
    |> Repo.update!()
  end

  ## Ref application

  defp apply_refs(operation, repository, plan) do
    with {:ok, temp_refs} <- retain_new_commits(operation, repository, plan) do
      move_public_refs(repository, plan, temp_refs)
    end
  end

  defp retain_new_commits(operation, repository, plan) do
    targets =
      [{"trunk", Map.fetch!(plan, "trunk_new")}] ++
        Enum.map(Map.fetch!(plan, "restacked"), fn step ->
          {"p#{Map.fetch!(step, "position")}", Map.fetch!(step, "new_head")}
        end)

    temp_refs =
      Enum.map(targets, fn {segment, oid} ->
        {:ok, ref} =
          GitPlane.internal_ref([
            "operations",
            operation.id,
            "a#{operation.attempt_count}",
            segment
          ])

        %{ref: ref, expected_old: :absent, new: oid}
      end)

    case GitPlane.batch_update_refs(repository.storage_key, temp_refs, principal(operation)) do
      {:ok, _result} -> {:ok, temp_refs}
      {:error, reason} -> {:error, {:retention_failed, reason}}
    end
  end

  # One atomic batch: the trunk and every restacked branch move together
  # and the retention refs delete in the same transaction. Merged lower
  # branches do not move and are not deleted.
  defp move_public_refs(repository, plan, temp_refs) do
    updates =
      [
        %{
          ref: Map.fetch!(plan, "trunk_ref"),
          expected_old: Map.fetch!(plan, "trunk_old"),
          new: Map.fetch!(plan, "trunk_new")
        }
      ] ++
        Enum.map(Map.fetch!(plan, "restacked"), fn step ->
          %{
            ref: Map.fetch!(step, "ref"),
            expected_old: Map.fetch!(step, "old_head"),
            new: Map.fetch!(step, "new_head")
          }
        end) ++
        Enum.map(temp_refs, fn temp ->
          %{ref: temp.ref, expected_old: temp.new, new: :delete}
        end)

    case GitPlane.batch_update_refs(repository.storage_key, updates, "stack-merge") do
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
    _result = GitPlane.batch_update_refs(repository.storage_key, deletes, "stack-merge")
    :ok
  end

  defp principal(operation), do: "stack-operation-" <> operation.id

  ## Finalization

  defp finalize(operation, stack, plan) do
    result =
      Repo.transaction(fn ->
        lock_repository_stacks(stack.repository_id)
        current = Repo.one!(from s in Stack, where: s.id == ^stack.id, lock: "FOR UPDATE")

        if current.version != operation.expected_stack_version do
          Repo.rollback({:version_moved, current.version})
        end

        now = DateTime.utc_now()
        Enum.each(Map.fetch!(plan, "merged"), &finalize_merged!(&1, operation, now))
        Enum.each(Map.fetch!(plan, "restacked"), &finalize_restacked!(&1, current, plan))

        stack_after = complete_or_bump!(current, plan)
        record_events!(stack_after, operation, plan)

        operation
        |> Operation.transition_changeset(%{
          state: "succeeded",
          planned_result: Map.put(plan, "refs_applied", true),
          completed_at: now
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> partially_succeed(operation, plan, reason)
    end
  end

  defp finalize_merged!(step, operation, now) do
    entry_id = Map.fetch!(step, "entry_id")
    pull_request_id = Map.fetch!(step, "pull_request_id")

    {1, _rows} =
      Repo.update_all(
        from(entry in StackEntry, where: entry.id == ^entry_id and is_nil(entry.removed_at)),
        set: [removed_at: now, updated_at: now]
      )

    pull_request =
      Repo.one!(
        from pr in PullRequest,
          where: pr.id == ^pull_request_id,
          lock: "FOR UPDATE"
      )

    {1, _rows} =
      Repo.update_all(
        from(pr in PullRequest, where: pr.id == ^pull_request_id),
        set: [
          state: "closed",
          merged_at: now,
          merged_by_user_id: operation.created_by_user_id,
          merge_commit_sha: Map.fetch!(step, "merge_commit_sha"),
          updated_at: now
        ]
      )

    {1, _rows} =
      Repo.update_all(
        from(issue in Issue, where: issue.id == ^pull_request.issue_id),
        set: [
          state: "closed",
          state_reason: "completed",
          closed_at: DateTime.truncate(now, :second),
          updated_at: DateTime.truncate(now, :second)
        ]
      )

    :ok
  end

  # The lowest remaining layer retargets the trunk; every higher layer
  # keeps its direct base and only its boundary and head advance.
  defp finalize_restacked!(step, stack, plan) do
    entry_id = Map.fetch!(step, "entry_id")
    new_boundary = Map.fetch!(step, "new_boundary")
    new_head = Map.fetch!(step, "new_head")
    lowest? = Map.fetch!(step, "new_boundary") == Map.fetch!(plan, "trunk_new")

    Repo.one!(from entry in StackEntry, where: entry.id == ^entry_id, lock: "FOR UPDATE")
    |> StackEntry.changeset(%{boundary_oid: new_boundary, observed_head_oid: new_head})
    |> Repo.update!()

    base_ref_set = if lowest?, do: [base_ref: stack.trunk_ref], else: []

    {1, _rows} =
      Repo.update_all(
        from(pr in PullRequest, where: pr.id == ^Map.fetch!(step, "pull_request_id")),
        set: [head_sha: new_head, base_sha: new_boundary] ++ base_ref_set
      )

    :ok
  end

  defp complete_or_bump!(stack, plan) do
    remaining = Map.fetch!(plan, "restacked") != []
    state = if remaining, do: "open", else: "completed"

    {1, [stack_after]} =
      Repo.update_all(
        from(s in Stack,
          where: s.id == ^stack.id and s.version == ^stack.version,
          select: s
        ),
        set: [
          version: stack.version + 1,
          health: "healthy",
          state: state,
          updated_at: DateTime.utc_now()
        ]
      )

    stack_after
  end

  defp record_events!(stack, operation, plan) do
    record_event!(stack, operation, "pull_request_stack.merge_completed", %{
      "stack_number" => stack.number,
      "operation_id" => operation.id,
      "trunk_ref" => stack.trunk_ref,
      "merge_method" => Map.fetch!(plan, "merge_method"),
      "trunk_old" => Map.fetch!(plan, "trunk_old"),
      "trunk_new" => Map.fetch!(plan, "trunk_new"),
      "pull_requests" =>
        Enum.map(Map.fetch!(plan, "merged"), &Map.fetch!(&1, "pull_request_number")),
      "merged" => Map.fetch!(plan, "merged")
    })

    Enum.each(Map.fetch!(plan, "merged"), fn step ->
      record_event!(stack, operation, "pull_request.unstacked", %{
        "stack_number" => stack.number,
        "operation_id" => operation.id,
        "pull_request" => Map.fetch!(step, "pull_request_number"),
        "reason" => "merged",
        "merge_commit_sha" => Map.fetch!(step, "merge_commit_sha")
      })
    end)

    Enum.each(Map.fetch!(plan, "restacked"), fn step ->
      record_event!(stack, operation, "pull_request.synchronize", %{
        "operation_id" => operation.id,
        "pull_request" => Map.fetch!(step, "pull_request_number"),
        "ref" => Map.fetch!(step, "ref"),
        "before" => Map.fetch!(step, "old_head"),
        "after" => Map.fetch!(step, "new_head")
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

  ## Terminal transitions

  # The refs landed but the metadata could not finalize: the merged pull
  # requests' code is on the trunk, so the operation records exactly what
  # applied instead of pretending nothing happened.
  defp partially_succeed(operation, plan, reason) do
    {:ok, operation} =
      Repo.transaction(fn ->
        stack = Repo.one!(from s in Stack, where: s.id == ^operation.stack_id, lock: "FOR UPDATE")

        record_event!(stack, operation, "pull_request_stack.merge_partially_completed", %{
          "stack_number" => stack.number,
          "operation_id" => operation.id,
          "trunk_ref" => stack.trunk_ref,
          "error" => error_map(reason)
        })

        operation
        |> Operation.transition_changeset(%{
          state: "partially_succeeded",
          error: error_map(reason),
          planned_result: Map.put(plan, "refs_applied", true),
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()
      end)

    {:error, operation}
  end

  defp fail(operation, stack, reason) do
    {:ok, operation} =
      Repo.transaction(fn ->
        current = Repo.one!(from s in Stack, where: s.id == ^stack.id, lock: "FOR UPDATE")
        set_health!(current, failure_health(reason))

        record_event!(current, operation, "pull_request_stack.merge_failed", %{
          "stack_number" => current.number,
          "operation_id" => operation.id,
          "trunk_ref" => current.trunk_ref,
          "error" => error_map(reason)
        })

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
  defp failure_health({:upper_restack_conflict, _conflict}), do: "conflicted"
  defp failure_health(:needs_rebase), do: "needs_rebase"
  defp failure_health(_reason), do: "needs_rebase"

  defp error_map({:head_changed, ref, actual}),
    do: %{"code" => "head_changed", "ref" => ref, "actual" => stringify_actual(actual)}

  defp error_map({:missing_ref, ref}), do: %{"code" => "missing_ref", "ref" => ref}

  defp error_map({:upper_restack_conflict, conflict}),
    do: Map.put(conflict, "code", "upper_restack_conflict")

  defp error_map({:replay_failed, position, reason}),
    do: %{"code" => "replay_failed", "position" => position, "reason" => inspect(reason)}

  defp error_map({:retention_failed, reason}),
    do: %{"code" => "retention_failed", "reason" => inspect(reason)}

  defp error_map({:ref_update_failed, reason}),
    do: %{"code" => "ref_update_failed", "reason" => inspect(reason)}

  defp error_map({:version_moved, version}),
    do: %{"code" => "version_moved", "stack_version" => version}

  defp error_map(reason) when is_atom(reason), do: %{"code" => Atom.to_string(reason)}
  defp error_map(reason), do: %{"code" => "operation_failed", "reason" => inspect(reason)}

  defp stringify_actual(:absent), do: "absent"
  defp stringify_actual(oid), do: oid

  ## Request validation

  defp authorize(repository, actor) do
    if Repositories.writable?(repository, actor), do: :ok, else: {:error, :forbidden}
  end

  defp parse_merge_request(params) do
    with {:ok, number} <- parse_pull_request_number(params),
         {:ok, method} <- parse_merge_method(params),
         :ok <- parse_merge_action(params),
         {:ok, version} <- parse_expected_version(params),
         {:ok, expected_heads} <- parse_expected_heads(params) do
      {:ok,
       %{
         "pull_request_number" => number,
         "merge_method" => method,
         "merge_action" => "direct_merge",
         "expected_stack_version" => version,
         "expected_heads" => expected_heads
       }}
    end
  end

  defp parse_pull_request_number(params) do
    case Map.get(params, "pull_request_number") do
      number when is_integer(number) and number >= 1 -> {:ok, number}
      _other -> {:error, :invalid_request}
    end
  end

  defp parse_merge_method(params) do
    case Map.get(params, "merge_method") do
      method when method in @merge_methods -> {:ok, method}
      _other -> {:error, :invalid_request}
    end
  end

  # No merge queue exists on the forge yet. OpenAgents.Stacks.MergeQueue
  # fixes the stack contract any queue implementation must satisfy; until
  # one lands, only a direct merge is available.
  defp parse_merge_action(params) do
    case Map.get(params, "merge_action", "direct_merge") do
      "direct_merge" -> :ok
      "queue" -> {:error, :merge_queue_unavailable}
      _other -> {:error, :invalid_request}
    end
  end

  defp parse_expected_version(params) do
    case Map.get(params, "expected_stack_version") do
      nil -> {:ok, nil}
      version when is_integer(version) and version >= 1 -> {:ok, version}
      _other -> {:error, :invalid_request}
    end
  end

  defp parse_expected_heads(params) do
    case Map.get(params, "expected_heads") do
      nil ->
        {:ok, nil}

      heads when is_map(heads) ->
        if Enum.all?(heads, fn {_key, oid} -> valid_oid_string?(oid) end),
          do: {:ok, heads},
          else: {:error, :invalid_request}

      _other ->
        {:error, :invalid_request}
    end
  end

  defp valid_oid_string?(oid) when is_binary(oid) and byte_size(oid) in [40, 64] do
    match?({:ok, _raw}, Base.decode16(oid, case: :lower))
  end

  defp valid_oid_string?(_oid), do: false

  defp selected_position(stack, request, replay) do
    number =
      case replay do
        %Operation{request: replayed} -> Map.fetch!(replayed, "pull_request_number")
        nil -> Map.fetch!(request, "pull_request_number")
      end

    entries = active_entries(stack)

    case Enum.find(entries, &(&1.pull_request.issue.number == number)) do
      %StackEntry{position: position} -> {:ok, position}
      nil -> {:error, :pull_request_not_in_stack}
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

  defp insert_operation!(stack, actor, key, request, position) do
    %Operation{}
    |> Operation.changeset(%{
      stack_id: stack.id,
      created_by_user_id: actor.id,
      kind: "merge",
      state: "pending",
      target_position: position,
      expected_stack_version: request["expected_stack_version"] || stack.version,
      idempotency_key: key,
      request: Map.put(request, "previous_health", stack.health),
      retry_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  ## Shared helpers

  defp tree_of(repository, oid) do
    case GitPlane.tree_of(repository.storage_key, oid) do
      {:ok, tree} -> {:ok, tree}
      {:error, reason} -> {:error, {:tree_read_failed, reason}}
    end
  end

  defp commit_author(repository, oid) do
    case GitPlane.commit_author(repository.storage_key, oid) do
      {:ok, author} -> {:ok, author}
      {:error, reason} -> {:error, {:author_read_failed, reason}}
    end
  end

  defp commit_tree(repository, tree, parents, message, opts \\ []) do
    case GitPlane.commit_tree(repository.storage_key, tree, parents, message, opts) do
      {:ok, oid} -> {:ok, oid}
      {:error, reason} -> {:error, {:commit_build_failed, reason}}
    end
  end

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

  defp active_entries(%Stack{id: stack_id}) do
    Repo.all(
      from entry in StackEntry,
        where: entry.stack_id == ^stack_id and is_nil(entry.removed_at),
        order_by: [asc: entry.position],
        preload: [pull_request: :issue]
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
end
