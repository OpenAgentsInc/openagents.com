defmodule OpenAgents.Stacks.RestackTest do
  @moduledoc """
  Cascading server-side rebase (#50): the bottom-to-top waterfall, conflict
  pause with a durable workspace, continue and abort, head re-verification
  on resume, atomic public ref movement with retention refs, operation
  idempotency, and crash recovery through the lease.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Operation
  alias OpenAgents.Stacks.OperationWorker
  alias OpenAgents.Stacks.Restack
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry
  alias OpenAgents.Stacks.StackEvent

  import Ecto.Query
  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  setup do
    base = Path.join(System.tmp_dir!(), "stack-restack-#{System.unique_integer([:positive])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    actor = repository_user_fixture("restack-actor")
    repository = repository_with_member_fixture(actor)

    %{actor: actor, repository: repository}
  end

  describe "a clean restack" do
    test "moves every branch, updates metadata, and emits events", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      trunk_tip = advance_trunk(path, oids["main"], "trunk.md")

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-1")

      assert operation.state == "pending"
      assert reload(Stack, stack.id).health == "operation_in_progress"

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"
      assert operation.snapshot["trunk_oid"] == trunk_tip
      assert operation.planned_result["moved"] == true

      stack = reload(Stack, stack.id)
      assert stack.version == 2
      assert stack.health == "healthy"

      new_layer_1 = show(path, ["rev-parse", "refs/heads/layer-1"])
      new_layer_2 = show(path, ["rev-parse", "refs/heads/layer-2"])
      refute new_layer_1 == oids["layer-1"]
      refute new_layer_2 == oids["layer-2"]

      assert show(path, ["rev-parse", "refs/heads/layer-1^"]) == trunk_tip
      assert show(path, ["rev-parse", "refs/heads/layer-2^"]) == new_layer_1

      [entry_1, entry_2] = entries(stack.id)
      assert entry_1.boundary_oid == trunk_tip
      assert entry_1.observed_head_oid == new_layer_1
      assert entry_2.boundary_oid == new_layer_1
      assert entry_2.observed_head_oid == new_layer_2

      pull_request_1 = Repo.one!(from pr in PullRequest, where: pr.id == ^entry_1.pull_request_id)
      assert pull_request_1.head_sha == new_layer_1
      assert pull_request_1.base_sha == trunk_tip

      assert Repo.exists?(
               from event in StackEvent,
                 where:
                   event.event_type == "pull_request_stack.rebased" and
                     event.stack_id == ^stack.id and event.stack_version == 2
             )

      synchronize_count =
        Repo.aggregate(
          from(event in StackEvent,
            where: event.event_type == "pull_request.synchronize" and event.stack_id == ^stack.id
          ),
          :count
        )

      assert synchronize_count == 2

      # The replacement commits keep the original author and message.
      assert show(path, ["show", "-s", "--format=%an <%ae>", new_layer_1]) ==
               "Test Author <author@example.test>"

      assert show(path, ["show", "-s", "--format=%s", new_layer_2]) == "Layer layer-2"
    end

    test "leaves no retention ref behind", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      advance_trunk(path, oids["main"], "trunk.md")

      {:ok, {_operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-refs-1")

      assert :processed = OperationWorker.run_once()

      {internal, 0} = Repos.git(path, ["for-each-ref", "refs/internal/"])
      assert internal == ""
    end

    test "an already-current stack succeeds without moving refs", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-noop-1")

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"
      assert operation.planned_result["moved"] == false

      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == oids["layer-1"]
      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == oids["layer-2"]
      assert reload(Stack, stack.id).health == "healthy"
    end
  end

  describe "a mid-stack conflict" do
    test "pauses with a durable workspace and no public ref moved", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_conflicting_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-conflict-1")

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "waiting_for_conflict_resolution"

      conflict = operation.conflict
      assert conflict["position"] == 2
      assert conflict["old_boundary"] == oids["layer-1"]
      assert conflict["old_head"] == oids["layer-2"]
      assert conflict["commit"] == oids["layer-2"]
      assert conflict["paths"] == ["shared.txt"]
      assert [%{"ref" => "refs/heads/layer-1"}] = conflict["steps"]

      assert reload(Stack, stack.id).health == "conflicted"

      # No public branch moved: the pause happened before any batch.
      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == oids["layer-1"]
      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == oids["layer-2"]
    end

    test "continue resumes from the resolution and completes the stack", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_conflicting_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-continue-1")

      assert :processed = OperationWorker.run_once()
      operation = reload(Operation, operation.id)
      assert operation.state == "waiting_for_conflict_resolution"

      onto = operation.conflict["onto"]
      resolution = commit(path, onto, "Resolve shared.txt", %{"shared.txt" => "resolved\n"})

      assert {:ok, %Operation{state: "pending"}} =
               Restack.continue_from_api(
                 repository,
                 stack.number,
                 operation.id,
                 %{"resolution_oid" => resolution},
                 actor
               )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"

      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == resolution
      refute show(path, ["rev-parse", "refs/heads/layer-1"]) == oids["layer-1"]

      stack = reload(Stack, stack.id)
      assert stack.health == "healthy"
      assert stack.version == 2
    end

    test "continue rejects a resolution that does not build on the persisted parent",
         context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_conflicting_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-badres-1")

      assert :processed = OperationWorker.run_once()
      operation = reload(Operation, operation.id)

      stray = commit(path, oids["main"], "Wrong parent", %{"stray.txt" => "stray\n"})

      assert {:error, :resolution_parent_mismatch} =
               Restack.continue_from_api(
                 repository,
                 stack.number,
                 operation.id,
                 %{"resolution_oid" => stray},
                 actor
               )

      assert {:error, :resolution_not_found} =
               Restack.continue_from_api(
                 repository,
                 stack.number,
                 operation.id,
                 %{"resolution_oid" => String.duplicate("0", 40)},
                 actor
               )
    end

    test "a resumed operation re-verifies every branch head first", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_conflicting_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-reverify-1")

      assert :processed = OperationWorker.run_once()
      operation = reload(Operation, operation.id)
      onto = operation.conflict["onto"]
      resolution = commit(path, onto, "Resolve shared.txt", %{"shared.txt" => "resolved\n"})

      assert {:ok, _operation} =
               Restack.continue_from_api(
                 repository,
                 stack.number,
                 operation.id,
                 %{"resolution_oid" => resolution},
                 actor
               )

      # A concurrent push lands on layer-1 before the worker resumes.
      concurrent = commit(path, oids["layer-1"], "Concurrent push", %{"race.txt" => "race\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", concurrent])

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "head_changed"

      assert reload(Stack, stack.id).health == "head_changed"
      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == concurrent
      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == oids["layer-2"]
    end

    test "abort cancels the paused operation and records the conflict", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_conflicting_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-abort-1")

      assert :processed = OperationWorker.run_once()

      assert {:ok, %Operation{state: "cancelled"}} =
               Restack.abort_from_api(repository, stack.number, operation.id, actor)

      assert reload(Stack, stack.id).health == "conflicted"

      assert {:error, :operation_not_abortable} =
               Restack.abort_from_api(repository, stack.number, operation.id, actor)
    end
  end

  describe "concurrent pushes" do
    test "a moved branch fails the operation and the user branch survives", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      advance_trunk(path, oids["main"], "trunk.md")

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-race-1")

      concurrent = commit(path, oids["layer-2"], "User push", %{"user.txt" => "mine\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-2", concurrent])

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "head_changed"
      assert operation.error["ref"] == "refs/heads/layer-2"

      assert reload(Stack, stack.id).health == "head_changed"
      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == oids["layer-1"]
      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == concurrent
    end

    test "a deleted branch fails the operation as missing_ref", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      advance_trunk(path, oids["main"], "trunk.md")

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-missing-1")

      {_, 0} = Repos.git(path, ["update-ref", "-d", "refs/heads/layer-2"])

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "missing_ref"
      assert reload(Stack, stack.id).health == "missing_ref"
    end
  end

  describe "request validation" do
    test "replays the same idempotency key and rejects a changed request", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-idem-1")

      {:ok, {replayed, :replayed}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-idem-1")

      assert replayed.id == operation.id
      assert Repo.aggregate(Operation, :count) == 1

      assert {:error, :idempotency_conflict} =
               Restack.request_from_api(
                 repository,
                 stack.number,
                 %{"expected_stack_version" => 1},
                 actor,
                 "restack-idem-1"
               )
    end

    test "rejects a second active operation and a stale expected version", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)

      assert {:error, :stale_stack_version} =
               Restack.request_from_api(
                 repository,
                 stack.number,
                 %{"expected_stack_version" => 9},
                 actor,
                 "restack-active-3"
               )

      {:ok, {_operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-active-1")

      assert {:error, :operation_in_progress} =
               Restack.request_from_api(repository, stack.number, %{}, actor, "restack-active-2")
    end

    test "rejects a caller without write access", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)
      outsider = repository_user_fixture("restack-outsider")

      assert {:error, :forbidden} =
               Restack.request_from_api(repository, stack.number, %{}, outsider, "restack-out-1")
    end

    test "a version that moves before execution fails the operation", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-stale-1")

      {1, _rows} =
        Repo.update_all(from(s in Stack, where: s.id == ^stack.id), set: [version: 5])

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "stale_stack_version"
    end
  end

  describe "crash recovery" do
    test "a stale running lease is reclaimed and executed to completion", context do
      %{repository: repository, actor: actor} = context
      %{path: path, oids: oids, stack: stack} = seed_stack(repository, actor)

      trunk_tip = advance_trunk(path, oids["main"], "trunk.md")

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-crash-1")

      # A worker claimed the row and crashed: the lease is stale.
      stale = DateTime.add(DateTime.utc_now(), -600, :second)

      {1, _rows} =
        Repo.update_all(
          from(o in Operation, where: o.id == ^operation.id),
          set: [state: "running", claimed_at: stale, attempt_count: 1]
        )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"
      assert operation.attempt_count == 2
      assert show(path, ["rev-parse", "refs/heads/layer-1^"]) == trunk_tip
    end

    test "an executor crash marks the operation failed", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Restack.request_from_api(repository, stack.number, %{}, actor, "restack-boom-1")

      assert :processed = OperationWorker.run_once(fn _operation -> raise "boom" end)

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "operation_exception"
    end
  end

  ## Fixtures

  # main ── layer-1 ── layer-2, each layer adding one file.
  defp seed_stack(repository, actor) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    main = commit(path, nil, "Seed repository", %{"README.md" => "readme\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    layer_1 = commit(path, main, "Layer layer-1", %{"layer-1.md" => "one\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", layer_1])

    layer_2 = commit(path, layer_1, "Layer layer-2", %{"layer-2.md" => "two\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-2", layer_2])

    oids = %{"main" => main, "layer-1" => layer_1, "layer-2" => layer_2}
    build_stack(repository, actor, path, oids)
  end

  # layer-2 rewrites shared.txt, and the trunk advance rewrites it too, so
  # layer-1 replays clean and layer-2 conflicts.
  defp seed_conflicting_stack(repository, actor) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    main = commit(path, nil, "Seed repository", %{"shared.txt" => "base\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    layer_1 = commit(path, main, "Layer layer-1", %{"layer-1.md" => "one\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", layer_1])

    layer_2 = commit(path, layer_1, "Layer layer-2", %{"shared.txt" => "layer two\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-2", layer_2])

    trunk = commit(path, main, "Trunk rewrite", %{"shared.txt" => "trunk\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", trunk])

    oids = %{"main" => main, "trunk" => trunk, "layer-1" => layer_1, "layer-2" => layer_2}
    build_stack(repository, actor, path, oids)
  end

  defp build_stack(repository, actor, path, oids) do
    bottom = pull_request(repository, "layer-1", "main", oids["main"], oids["layer-1"])
    top = pull_request(repository, "layer-2", "layer-1", oids["layer-1"], oids["layer-2"])

    {:ok, stack} = Stacks.create(repository, [bottom, top], actor)

    %{path: path, oids: oids, stack: stack, pull_requests: [bottom, top]}
  end

  defp advance_trunk(path, parent, file) do
    trunk_tip = commit(path, parent, "Trunk advance", %{file => "trunk\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", trunk_tip])
    trunk_tip
  end

  defp pull_request(repository, head_ref, base_ref, base_sha, head_sha) do
    issue = issue_fixture(repository, %{title: "PR #{head_ref}"})

    {:ok, pull_request} =
      %PullRequest{}
      |> PullRequest.changeset(%{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: repository.id,
        head_ref: head_ref,
        head_sha: head_sha,
        base_ref: base_ref,
        base_sha: base_sha,
        state: "open"
      })
      |> Repo.insert()

    Repo.preload(pull_request, :issue)
  end

  # Commits a tree that layers the given files over the parent's tree.
  defp commit(path, parent, message, files) do
    parent_entries =
      if parent do
        {listing, 0} = Repos.git(path, ["ls-tree", parent])

        listing
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [meta, name] = String.split(line, "\t", parts: 2)
          {name, meta <> "\t" <> name}
        end)
      else
        %{}
      end

    new_entries =
      Map.new(files, fn {name, content} ->
        blob = git!(path, ["hash-object", "-w", "--stdin"], content)
        {name, "100644 blob #{blob}\t#{name}"}
      end)

    listing =
      parent_entries
      |> Map.merge(new_entries)
      |> Map.values()
      |> Enum.map_join("", &(&1 <> "\n"))

    tree = git!(path, ["mktree"], listing)
    parent_args = if parent, do: ["-p", parent], else: []

    git!(path, ["commit-tree", tree] ++ parent_args ++ ["-m", message], "",
      env: [
        {"GIT_AUTHOR_NAME", "Test Author"},
        {"GIT_AUTHOR_EMAIL", "author@example.test"},
        {"GIT_COMMITTER_NAME", "Test Author"},
        {"GIT_COMMITTER_EMAIL", "author@example.test"}
      ]
    )
  end

  defp entries(stack_id) do
    Repo.all(
      from entry in StackEntry,
        where: entry.stack_id == ^stack_id and is_nil(entry.removed_at),
        order_by: [asc: entry.position]
    )
  end

  defp reload(schema, id), do: Repo.get!(schema, id)

  defp show(path, args) do
    {output, 0} = Repos.git(path, args)
    String.trim(output)
  end

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(System.tmp_dir!(), "restack-input-#{System.unique_integer([:positive])}")

    File.write!(input_path, input)

    try do
      {output, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec git --git-dir "$GIT_DIR" "$@" < "$INPUT"), "sh"] ++ args,
          env: [{"GIT_DIR", git_dir}, {"INPUT", input_path}] ++ Keyword.get(options, :env, [])
        )

      String.trim(output)
    after
      File.rm(input_path)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
