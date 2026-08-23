defmodule OpenAgents.Stacks.Checks do
  @moduledoc """
  Stack-aware check planning (docs/stacked-prs.md sections 11.3–11.5).

  Checks on a stacked pull request test an immutable snapshot that includes
  every lower layer. Each planned run keys its validity to the full context
  — `(pull_request_id, workflow_name, context, head_oid, effective_base_oid,
  workflow_definition_oid)` — so a trunk advance, a head move, or a workflow
  definition change produces a different identity instead of reusing a
  verdict for a state that no longer exists. Planning marks runs whose
  effective base no longer matches the trunk tip `stale` before creating
  runs for the current identity.

  When a layer head does not already sit on the snapshot base (the stack
  needs a rebase, or the plan speculates for a merge group), the snapshot
  is a boundary-scoped replay of the layer chain onto the current trunk,
  published once under `refs/internal/checks/<run-id>` with an
  expected-absent compare-and-swap. Nothing ever moves that ref afterward:
  the run's snapshot is immutable for its lifetime.

  Workflow definitions live in `#{inspect(".forge/workflows.json")}` in the
  effective-base tree — never an intermediate branch tree — and each
  workflow declares an explicit `run_on` policy: `every_layer`,
  `top_layer_only`, `bottom_layer_only`, `changed_paths` (with declared
  path prefixes), or `merge_group_only`. A plan skips a layer only through
  that declared policy, and every skip is returned explicitly in the plan
  rather than silently dropped. In the `merge_group` context every workflow
  runs: the merge group is the authoritative gate and never optimizes a
  required check away.
  """

  import Ecto.Query

  alias OpenAgents.Forge.Browse
  alias OpenAgents.Forge.GitPlane
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.CheckRun
  alias OpenAgents.Stacks.Stack

  @workflows_path ".forge/workflows.json"
  @principal "stack-checks"

  @doc "The path of the workflow definitions file in the effective-base tree."
  def workflows_path, do: @workflows_path

  @doc """
  The workflow definitions governing checks at `base_oid`.

  Reads `#{inspect(".forge/workflows.json")}` from the given commit's tree and
  returns `{:ok, %{definition_oid: blob_oid, workflows: [workflow]}}` where
  each workflow has `name`, `run_on`, `required`, and `paths`. Returns
  `{:error, :no_workflows}` when the file is absent and
  `{:error, {:invalid_workflows, reason}}` when it does not parse into the
  declared policy shape.
  """
  def workflows(%Repository{} = repository, base_oid) do
    with {:ok, definition_oid} <- definition_oid(repository, base_oid),
         {:ok, blob} <- read_blob(repository, base_oid),
         {:ok, workflows} <- parse_workflows(blob.content) do
      {:ok, %{definition_oid: definition_oid, workflows: workflows}}
    end
  end

  @doc """
  Plan check runs for every active layer of `stack` against the current
  trunk tip.

  Marks runs whose effective base is no longer the trunk tip `stale`, then
  creates (or reuses, by identity) one run per layer and workflow that the
  declared `run_on` policy selects. Pass `context: "merge_group"` to plan
  the merge-group gate, where every workflow runs.

  Returns `{:ok, %{trunk_oid, definition_oid, runs, skipped, invalidated}}`
  where `skipped` lists each `(position, workflow)` the declared policy
  excluded — a skip is always explicit, never silent.
  """
  def plan(%Repository{} = repository, %Stack{} = stack, opts \\ []) do
    context = Keyword.get(opts, :context, "layer")

    with :ok <- check_context(context),
         {:ok, trunk_oid} <- resolve(repository, stack.trunk_ref),
         {:ok, %{definition_oid: definition_oid, workflows: workflows}} <-
           workflows(repository, trunk_oid) do
      entries = Stacks.active_entries(stack)
      invalidated = mark_stale(stack, trunk_oid)

      with {:ok, snapshots} <- snapshots(repository, entries, trunk_oid),
           {:ok, runs, skipped} <-
             materialize(repository, stack, entries, workflows, snapshots, %{
               context: context,
               trunk_oid: trunk_oid,
               definition_oid: definition_oid
             }) do
        {:ok,
         %{
           trunk_oid: trunk_oid,
           definition_oid: definition_oid,
           runs: runs,
           skipped: skipped,
           invalidated: invalidated
         }}
      end
    end
  end

  @doc """
  Mark every non-concluded run of `stack` whose effective base is not the
  current trunk tip as `stale`, so a trunk advance invalidates affected
  checks. Returns `{:ok, %{trunk_oid, invalidated}}`.
  """
  def refresh(%Repository{} = repository, %Stack{} = stack) do
    with {:ok, trunk_oid} <- resolve(repository, stack.trunk_ref) do
      {:ok, %{trunk_oid: trunk_oid, invalidated: mark_stale(stack, trunk_oid)}}
    end
  end

  @doc "Concludes a pending run as `passed` or `failed`."
  def report(%CheckRun{state: "pending"} = run, state) when state in ~w(passed failed) do
    Repo.update(CheckRun.conclusion_changeset(run, state, DateTime.utc_now()))
  end

  def report(%CheckRun{}, state) when state in ~w(passed failed),
    do: {:error, :not_pending}

  @doc "All runs of a stack, bottom layer first, newest identity last."
  def runs(%Stack{id: stack_id}) do
    Repo.all(
      from run in CheckRun,
        where: run.stack_id == ^stack_id,
        order_by: [asc: run.inserted_at, asc: run.id]
    )
  end

  ## Workflow definitions

  defp definition_oid(repository, base_oid) do
    path = Repos.bare_path(repository.storage_key)

    case Repos.git(path, ["rev-parse", "--verify", "--quiet", base_oid <> ":" <> @workflows_path]) do
      {output, 0} -> {:ok, String.trim(output)}
      _other -> {:error, :no_workflows}
    end
  end

  defp read_blob(repository, base_oid) do
    case Browse.blob(repository, base_oid, @workflows_path) do
      {:ok, blob} -> {:ok, blob}
      _other -> {:error, :no_workflows}
    end
  end

  defp parse_workflows(content) do
    case Jason.decode(content) do
      {:ok, %{"workflows" => workflows}} when is_list(workflows) ->
        parse_each(workflows, [])

      {:ok, _other} ->
        {:error, {:invalid_workflows, :missing_workflows_list}}

      {:error, _reason} ->
        {:error, {:invalid_workflows, :malformed_json}}
    end
  end

  defp parse_each([], parsed), do: {:ok, Enum.reverse(parsed)}

  defp parse_each([workflow | rest], parsed) do
    case parse_workflow(workflow) do
      {:ok, parsed_workflow} -> parse_each(rest, [parsed_workflow | parsed])
      {:error, reason} -> {:error, {:invalid_workflows, reason}}
    end
  end

  defp parse_workflow(%{"name" => name, "run_on" => run_on} = workflow)
       when is_binary(name) and name != "" do
    cond do
      run_on not in CheckRun.run_on_policies() ->
        {:error, {:unknown_run_on, name, run_on}}

      run_on == "changed_paths" and not valid_paths?(Map.get(workflow, "paths")) ->
        {:error, {:missing_paths, name}}

      not is_boolean(Map.get(workflow, "required", false)) ->
        {:error, {:invalid_required, name}}

      true ->
        {:ok,
         %{
           name: name,
           run_on: run_on,
           required: Map.get(workflow, "required", false),
           paths: Map.get(workflow, "paths", [])
         }}
    end
  end

  defp parse_workflow(_other), do: {:error, :invalid_workflow_entry}

  defp valid_paths?(paths) do
    is_list(paths) and paths != [] and Enum.all?(paths, &(is_binary(&1) and &1 != ""))
  end

  ## Run selection

  defp check_context(context) when context in ~w(layer merge_group), do: :ok
  defp check_context(_other), do: {:error, :invalid_context}

  # In the merge-group context every workflow runs: the merge group is the
  # authoritative gate. In the layer context the declared run_on policy
  # selects layers, and changed_paths consults the layer's own diff.
  defp selects?(_workflow, _entry, _top, "merge_group", _changed), do: true

  defp selects?(workflow, entry, top, "layer", changed) do
    case workflow.run_on do
      "every_layer" -> true
      "top_layer_only" -> entry.position == top
      "bottom_layer_only" -> entry.position == 1
      "changed_paths" -> Enum.any?(changed, &path_selected?(&1, workflow.paths))
      "merge_group_only" -> false
    end
  end

  # A declared path selects a changed file when it names the file exactly
  # or is a directory prefix.
  defp path_selected?(changed_path, declared_paths) do
    Enum.any?(declared_paths, fn declared ->
      prefix = String.trim_trailing(declared, "/")
      changed_path == prefix or String.starts_with?(changed_path, prefix <> "/")
    end)
  end

  defp changed_paths(repository, entry) do
    path = Repos.bare_path(repository.storage_key)

    args = [
      "diff",
      "--name-only",
      "--end-of-options",
      entry.boundary_oid,
      entry.observed_head_oid
    ]

    case Repos.git(path, args) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      _other -> {:error, {:diff_failed, entry.position}}
    end
  end

  ## Snapshots

  # Each snapshot is the cumulative repository state through a layer:
  # current trunk plus every layer up to and including this position. A
  # head that already sits on the chain (its boundary is the previous
  # snapshot) is its own snapshot; otherwise the layer replays onto the
  # chain and the result is published as a synthetic commit.
  defp snapshots(repository, entries, trunk_oid) do
    entries
    |> Enum.reduce_while({:ok, trunk_oid, %{}}, fn entry, {:ok, parent, acc} ->
      case snapshot_for(repository, entry, parent) do
        {:ok, snapshot} ->
          {:cont, {:ok, snapshot.tested_oid, Map.put(acc, entry.position, snapshot)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _parent, snapshots} -> {:ok, snapshots}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_for(_repository, %{boundary_oid: boundary} = entry, parent)
       when boundary == parent do
    {:ok, %{tested_oid: entry.observed_head_oid, synthetic: false}}
  end

  defp snapshot_for(repository, entry, parent) do
    case GitPlane.replay(
           repository.storage_key,
           entry.boundary_oid,
           entry.observed_head_oid,
           parent
         ) do
      {:ok, %{new_head: new_head}} ->
        {:ok, %{tested_oid: new_head, synthetic: true}}

      {:conflict, conflict} ->
        {:error, {:snapshot_conflict, entry.position, Map.get(conflict, :paths, [])}}

      {:error, reason} ->
        {:error, {:snapshot_failed, entry.position, reason}}
    end
  end

  ## Materialization

  defp materialize(repository, stack, entries, workflows, snapshots, plan) do
    top = entries |> Enum.map(& &1.position) |> Enum.max()

    entries
    |> Enum.reduce_while({:ok, [], []}, fn entry, {:ok, runs, skipped} ->
      case layer_runs(repository, stack, entry, workflows, snapshots, plan, top) do
        {:ok, layer_runs, layer_skipped} ->
          {:cont, {:ok, runs ++ layer_runs, skipped ++ layer_skipped}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, runs, skipped} -> {:ok, runs, skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp layer_runs(repository, stack, entry, workflows, snapshots, plan, top) do
    with {:ok, changed} <- layer_changed_paths(repository, entry, workflows, plan.context) do
      workflows
      |> Enum.reduce_while({:ok, [], []}, fn workflow, {:ok, runs, skipped} ->
        if selects?(workflow, entry, top, plan.context, changed) do
          case ensure_run(repository, stack, entry, workflow, snapshots, plan) do
            {:ok, run} -> {:cont, {:ok, [run | runs], skipped}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          skip = %{position: entry.position, workflow: workflow.name, policy: workflow.run_on}
          {:cont, {:ok, runs, [skip | skipped]}}
        end
      end)
      |> case do
        {:ok, runs, skipped} -> {:ok, Enum.reverse(runs), Enum.reverse(skipped)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp layer_changed_paths(repository, entry, workflows, "layer") do
    if Enum.any?(workflows, &(&1.run_on == "changed_paths")) do
      changed_paths(repository, entry)
    else
      {:ok, []}
    end
  end

  defp layer_changed_paths(_repository, _entry, _workflows, _context), do: {:ok, []}

  defp ensure_run(repository, stack, entry, workflow, snapshots, plan) do
    snapshot = Map.fetch!(snapshots, entry.position)

    case existing_run(entry.pull_request_id, workflow.name, plan, entry.observed_head_oid) do
      %CheckRun{} = run -> {:ok, run}
      nil -> create_run(repository, stack, entry, workflow, snapshot, plan)
    end
  end

  defp existing_run(pull_request_id, workflow_name, plan, head_oid) do
    Repo.one(
      from run in CheckRun,
        where:
          run.pull_request_id == ^pull_request_id and
            run.workflow_name == ^workflow_name and
            run.context == ^plan.context and
            run.head_oid == ^head_oid and
            run.effective_base_oid == ^plan.trunk_oid and
            run.workflow_definition_oid == ^plan.definition_oid and
            run.state != "stale"
    )
  end

  defp create_run(repository, stack, entry, workflow, snapshot, plan) do
    run_id = Ecto.UUID.generate()

    synthetic_ref =
      if snapshot.synthetic do
        {:ok, ref} = GitPlane.internal_ref(["checks", run_id])
        ref
      end

    changeset =
      CheckRun.changeset(%CheckRun{}, %{
        id: run_id,
        repository_id: repository.id,
        stack_id: stack.id,
        pull_request_id: entry.pull_request_id,
        workflow_name: workflow.name,
        run_on: workflow.run_on,
        required: workflow.required,
        run_reason: "policy",
        context: plan.context,
        head_oid: entry.observed_head_oid,
        effective_base_oid: plan.trunk_oid,
        workflow_definition_oid: plan.definition_oid,
        tested_oid: snapshot.tested_oid,
        synthetic_ref: synthetic_ref
      })

    with {:ok, run} <- Repo.insert(changeset),
         :ok <- publish_synthetic_ref(repository, run) do
      {:ok, run}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:run_invalid, changeset}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The synthetic ref publishes exactly once, from absent, and nothing ever
  # moves it: the snapshot a run tested is immutable for the run's lifetime.
  defp publish_synthetic_ref(_repository, %CheckRun{synthetic_ref: nil}), do: :ok

  defp publish_synthetic_ref(repository, %CheckRun{} = run) do
    updates = [%{ref: run.synthetic_ref, expected_old: :absent, new: run.tested_oid}]

    case GitPlane.batch_update_refs(repository.storage_key, updates, @principal) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:synthetic_ref_failed, reason}}
    end
  end

  ## Invalidation

  defp mark_stale(stack, trunk_oid) do
    {count, _rows} =
      Repo.update_all(
        from(run in CheckRun,
          where:
            run.stack_id == ^stack.id and
              run.state in ["pending", "passed"] and
              run.effective_base_oid != ^trunk_oid
        ),
        set: [state: "stale", updated_at: DateTime.utc_now()]
      )

    count
  end

  defp resolve(repository, ref) do
    case Browse.resolve_commit(repository, ref) do
      {:ok, oid} -> {:ok, oid}
      _other -> {:error, {:unresolved_ref, ref}}
    end
  end
end
