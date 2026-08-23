defmodule OpenAgents.Stacks.MergeTest do
  @moduledoc """
  Contiguous-prefix stack merge (#51): the merge-commit, squash, and rebase
  methods with exact resulting histories, prefix enforcement, upper-layer
  restacking after a partial merge, preflight failures, and injected crash
  recovery through the persisted plan.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Issues.Issue
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Merge
  alias OpenAgents.Stacks.Operation
  alias OpenAgents.Stacks.OperationWorker
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry
  alias OpenAgents.Stacks.StackEvent

  import Ecto.Query
  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  setup do
    base = Path.join(System.tmp_dir!(), "stack-merge-#{System.unique_integer([:positive])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    actor = repository_user_fixture("merge-actor")
    repository = repository_with_member_fixture(actor)

    %{actor: actor, repository: repository}
  end

  describe "the merge-commit method" do
    test "lands one group merge commit whose tree is the selected top head's", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
          actor,
          "merge-1"
        )

      assert operation.state == "pending"
      assert operation.target_position == 2
      assert reload(Stack, stack.id).health == "operation_in_progress"

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"

      merge_commit = show(path, ["rev-parse", "refs/heads/main"])
      parents = show(path, ["show", "-s", "--format=%P", merge_commit])
      assert parents == "#{oids["main"]} #{oids["layer-2"]}"

      assert show(path, ["rev-parse", merge_commit <> "^{tree}"]) ==
               show(path, ["rev-parse", oids["layer-2"] <> "^{tree}"])

      # Both selected pull requests merged with the group merge commit.
      for pr <- [pr_1, pr_2] do
        merged = Repo.one!(from p in PullRequest, where: p.id == ^pr.id)
        assert merged.state == "closed"
        assert merged.merge_commit_sha == merge_commit
        assert merged.merged_by_user_id == actor.id
        refute is_nil(merged.merged_at)

        issue = Repo.one!(from i in Issue, where: i.id == ^pr.issue_id)
        assert issue.state == "closed"
        assert issue.state_reason == "completed"
      end

      # The merged branches did not move and were not deleted.
      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == oids["layer-1"]
      assert show(path, ["rev-parse", "refs/heads/layer-2"]) == oids["layer-2"]

      stack = reload(Stack, stack.id)
      assert stack.state == "completed"
      assert stack.health == "healthy"
      assert stack.version == 2
      assert entries(stack.id) == []

      assert Repo.exists?(
               from event in StackEvent,
                 where:
                   event.event_type == "pull_request_stack.merge_completed" and
                     event.stack_id == ^stack.id
             )

      {internal, 0} = Repos.git(path, ["for-each-ref", "refs/internal/"])
      assert internal == ""
    end
  end

  describe "the squash method" do
    test "chains one commit per pull request so each trunk commit is one layer", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {_operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "squash"},
          actor,
          "squash-1"
        )

      assert :processed = OperationWorker.run_once()

      squash_2 = show(path, ["rev-parse", "refs/heads/main"])
      squash_1 = show(path, ["rev-parse", squash_2 <> "^"])
      assert show(path, ["rev-parse", squash_1 <> "^"]) == oids["main"]

      # Each squash commit's tree is exactly its layer head's tree.
      assert show(path, ["rev-parse", squash_1 <> "^{tree}"]) ==
               show(path, ["rev-parse", oids["layer-1"] <> "^{tree}"])

      assert show(path, ["rev-parse", squash_2 <> "^{tree}"]) ==
               show(path, ["rev-parse", oids["layer-2"] <> "^{tree}"])

      # Messages name the pull request and the original author survives.
      assert show(path, ["show", "-s", "--format=%s", squash_1]) ==
               "PR layer-1 (##{pr_1.issue.number})"

      assert show(path, ["show", "-s", "--format=%an <%ae>", squash_1]) ==
               "Test Author <author@example.test>"

      merged_1 = Repo.one!(from p in PullRequest, where: p.id == ^pr_1.id)
      merged_2 = Repo.one!(from p in PullRequest, where: p.id == ^pr_2.id)
      assert merged_1.merge_commit_sha == squash_1
      assert merged_2.merge_commit_sha == squash_2
    end
  end

  describe "the rebase method" do
    test "replays each layer's commits in order onto the trunk", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [_pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {_operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "rebase"},
          actor,
          "rebase-1"
        )

      assert :processed = OperationWorker.run_once()

      new_tip = show(path, ["rev-parse", "refs/heads/main"])
      new_mid = show(path, ["rev-parse", new_tip <> "^"])
      assert show(path, ["rev-parse", new_mid <> "^"]) == oids["main"]

      # The final tree equals the selected top head's tree, and the replayed
      # commits keep their messages.
      assert show(path, ["rev-parse", new_tip <> "^{tree}"]) ==
               show(path, ["rev-parse", oids["layer-2"] <> "^{tree}"])

      assert show(path, ["show", "-s", "--format=%s", new_mid]) == "Layer layer-1"
      assert show(path, ["show", "-s", "--format=%s", new_tip]) == "Layer layer-2"
    end
  end

  describe "prefix enforcement" do
    test "selecting the bottom layer merges only it and restacks the layers above", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {_operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_1.issue.number, "merge_method" => "merge"},
          actor,
          "prefix-1"
        )

      assert :processed = OperationWorker.run_once()

      trunk_new = show(path, ["rev-parse", "refs/heads/main"])

      merged_1 = Repo.one!(from p in PullRequest, where: p.id == ^pr_1.id)
      assert merged_1.state == "closed"
      assert merged_1.merge_commit_sha == trunk_new

      # The upper layer stays open, restacked onto the merge result, and
      # retargets the trunk.
      open_2 = Repo.one!(from p in PullRequest, where: p.id == ^pr_2.id)
      assert open_2.state == "open"
      assert open_2.base_ref == "main"
      assert open_2.base_sha == trunk_new

      new_layer_2 = show(path, ["rev-parse", "refs/heads/layer-2"])
      refute new_layer_2 == oids["layer-2"]
      assert show(path, ["rev-parse", new_layer_2 <> "^"]) == trunk_new
      assert open_2.head_sha == new_layer_2

      stack = reload(Stack, stack.id)
      assert stack.state == "open"
      assert stack.health == "healthy"

      [entry_2] = entries(stack.id)
      assert entry_2.boundary_oid == trunk_new
      assert entry_2.observed_head_oid == new_layer_2

      assert Repo.exists?(
               from event in StackEvent,
                 where:
                   event.event_type == "pull_request.synchronize" and
                     event.stack_id == ^stack.id
             )
    end

    test "a lower-prefix merge restacks every upper layer in order", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2, pr_3, pr_4]} =
        seed_stack(repository, actor, ["layer-1", "layer-2", "layer-3", "layer-4"])

      {:ok, {_operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "squash"},
          actor,
          "prefix-multi-1"
        )

      assert :processed = OperationWorker.run_once()

      trunk_new = show(path, ["rev-parse", "refs/heads/main"])

      for pr <- [pr_1, pr_2] do
        assert Repo.one!(from p in PullRequest, where: p.id == ^pr.id).state == "closed"
      end

      # Layer 3 restacked onto the squash result, layer 4 onto the new
      # layer 3, and only the lowest remaining layer retargets the trunk.
      new_layer_3 = show(path, ["rev-parse", "refs/heads/layer-3"])
      new_layer_4 = show(path, ["rev-parse", "refs/heads/layer-4"])
      refute new_layer_3 == oids["layer-3"]
      refute new_layer_4 == oids["layer-4"]
      assert show(path, ["rev-parse", new_layer_3 <> "^"]) == trunk_new
      assert show(path, ["rev-parse", new_layer_4 <> "^"]) == new_layer_3

      open_3 = Repo.one!(from p in PullRequest, where: p.id == ^pr_3.id)
      assert open_3.state == "open"
      assert open_3.base_ref == "main"
      assert open_3.base_sha == trunk_new
      assert open_3.head_sha == new_layer_3

      open_4 = Repo.one!(from p in PullRequest, where: p.id == ^pr_4.id)
      assert open_4.state == "open"
      assert open_4.base_ref == "layer-3"
      assert open_4.base_sha == new_layer_3
      assert open_4.head_sha == new_layer_4

      stack = reload(Stack, stack.id)
      assert stack.state == "open"
      assert stack.health == "healthy"

      [entry_3, entry_4] = entries(stack.id)
      assert entry_3.boundary_oid == trunk_new
      assert entry_3.observed_head_oid == new_layer_3
      assert entry_4.boundary_oid == new_layer_3
      assert entry_4.observed_head_oid == new_layer_4
    end

    test "a pull request outside the stack cannot be selected", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor)

      assert {:error, :pull_request_not_in_stack} =
               Merge.request_from_api(
                 repository,
                 stack.number,
                 %{"pull_request_number" => 999_999, "merge_method" => "merge"},
                 actor,
                 "prefix-missing-1"
               )
    end
  end

  describe "preflight" do
    test "a stack behind its trunk fails with needs_rebase before any ref moves", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [_pr_1, pr_2]} =
        seed_stack(repository, actor)

      trunk_tip = commit(path, oids["main"], "Trunk advance", %{"trunk.md" => "trunk\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", trunk_tip])

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
          actor,
          "behind-1"
        )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "needs_rebase"
      assert reload(Stack, stack.id).health == "needs_rebase"

      assert show(path, ["rev-parse", "refs/heads/main"]) == trunk_tip
      assert Repo.one!(from p in PullRequest, where: p.id == ^pr_2.id).state == "open"
    end

    test "a concurrent branch push fails the merge and preserves the branch", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [_pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
          actor,
          "race-1"
        )

      pushed = commit(path, oids["layer-1"], "User push", %{"extra.md" => "extra\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", pushed])

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "head_changed"

      assert show(path, ["rev-parse", "refs/heads/layer-1"]) == pushed
      assert show(path, ["rev-parse", "refs/heads/main"]) == oids["main"]
    end

    test "an expected head mismatch fails before any ref moves", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor)

      wrong = String.duplicate("ab", 20)

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{
            "pull_request_number" => pr_2.issue.number,
            "merge_method" => "merge",
            "expected_heads" => %{"#{pr_1.issue.number}" => wrong}
          },
          actor,
          "expected-1"
        )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "failed"
      assert operation.error["code"] == "expected_head_mismatch"
      assert show(path, ["rev-parse", "refs/heads/main"]) == oids["main"]
    end

    test "a stale expected stack version is rejected at request time", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack, pull_requests: [_pr_1, pr_2]} = seed_stack(repository, actor)

      assert {:error, :stale_stack_version} =
               Merge.request_from_api(
                 repository,
                 stack.number,
                 %{
                   "pull_request_number" => pr_2.issue.number,
                   "merge_method" => "merge",
                   "expected_stack_version" => 42
                 },
                 actor,
                 "stale-1"
               )
    end

    test "queueing is not yet available", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack, pull_requests: [_pr_1, pr_2]} = seed_stack(repository, actor)

      assert {:error, :merge_queue_unavailable} =
               Merge.request_from_api(
                 repository,
                 stack.number,
                 %{
                   "pull_request_number" => pr_2.issue.number,
                   "merge_method" => "merge",
                   "merge_action" => "queue"
                 },
                 actor,
                 "queue-1"
               )
    end

    test "a reader cannot request a merge", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack, pull_requests: [_pr_1, pr_2]} = seed_stack(repository, actor)
      reader = repository_user_fixture("merge-reader")

      assert {:error, :forbidden} =
               Merge.request_from_api(
                 repository,
                 stack.number,
                 %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
                 reader,
                 "reader-1"
               )
    end
  end

  describe "idempotency" do
    test "a retried key replays the original operation", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack, pull_requests: [_pr_1, pr_2]} = seed_stack(repository, actor)

      request = %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"}

      {:ok, {operation, :created}} =
        Merge.request_from_api(repository, stack.number, request, actor, "idem-1")

      assert {:ok, {replayed, :replayed}} =
               Merge.request_from_api(repository, stack.number, request, actor, "idem-1")

      assert replayed.id == operation.id

      assert {:error, :idempotency_conflict} =
               Merge.request_from_api(
                 repository,
                 stack.number,
                 Map.put(request, "merge_method", "squash"),
                 actor,
                 "idem-1"
               )
    end
  end

  describe "crash recovery" do
    test "a crash between the git refs and the metadata reconciles to success", context do
      %{repository: repository, actor: actor} = context
      %{path: path, stack: stack, pull_requests: [pr_1, pr_2]} = seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
          actor,
          "crash-1"
        )

      # A worker claims the row, moves the refs, and dies before the
      # metadata transaction.
      {1, _rows} =
        Repo.update_all(
          from(o in Operation, where: o.id == ^operation.id),
          set: [state: "running", claimed_at: DateTime.utc_now(), attempt_count: 1]
        )

      claimed = reload(Operation, operation.id)

      assert_raise RuntimeError, "injected crash", fn ->
        Merge.execute(claimed, after_refs: fn -> raise "injected crash" end)
      end

      # The refs landed but the metadata did not: the pull requests still
      # read open and the plan is marked applied.
      crashed = reload(Operation, operation.id)
      assert crashed.state == "running"
      assert crashed.planned_result["refs_applied"] == true
      assert show(path, ["rev-parse", "refs/heads/main"]) == crashed.planned_result["trunk_new"]
      assert Repo.one!(from p in PullRequest, where: p.id == ^pr_1.id).state == "open"

      # The lease expires and another worker reconciles instead of
      # re-merging.
      stale = DateTime.add(DateTime.utc_now(), -600, :second)

      {1, _rows} =
        Repo.update_all(
          from(o in Operation, where: o.id == ^operation.id),
          set: [claimed_at: stale]
        )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "succeeded"
      assert operation.attempt_count == 2

      trunk_new = show(path, ["rev-parse", "refs/heads/main"])
      assert trunk_new == operation.planned_result["trunk_new"]

      for pr <- [pr_1, pr_2] do
        merged = Repo.one!(from p in PullRequest, where: p.id == ^pr.id)
        assert merged.state == "closed"
        assert merged.merge_commit_sha == trunk_new
      end

      assert reload(Stack, stack.id).state == "completed"
    end

    test "a crash after a diverged repository marks the operation partial", context do
      %{repository: repository, actor: actor} = context

      %{path: path, oids: oids, stack: stack, pull_requests: [_pr_1, pr_2]} =
        seed_stack(repository, actor)

      {:ok, {operation, :created}} =
        Merge.request_from_api(
          repository,
          stack.number,
          %{"pull_request_number" => pr_2.issue.number, "merge_method" => "merge"},
          actor,
          "diverge-1"
        )

      {1, _rows} =
        Repo.update_all(
          from(o in Operation, where: o.id == ^operation.id),
          set: [state: "running", claimed_at: DateTime.utc_now(), attempt_count: 1]
        )

      claimed = reload(Operation, operation.id)

      assert_raise RuntimeError, "injected crash", fn ->
        Merge.execute(claimed, after_refs: fn -> raise "injected crash" end)
      end

      # A trunk push lands after the crash, so the live refs no longer match
      # the plan.
      trunk_new = show(path, ["rev-parse", "refs/heads/main"])
      diverged = commit(path, trunk_new, "Post-crash push", %{"post.md" => "post\n"})

      {:ok, _result} =
        OpenAgents.Forge.GitPlane.batch_update_refs(
          repository.storage_key,
          [%{ref: "refs/heads/main", expected_old: trunk_new, new: diverged}],
          "test-push"
        )

      stale = DateTime.add(DateTime.utc_now(), -600, :second)

      {1, _rows} =
        Repo.update_all(
          from(o in Operation, where: o.id == ^operation.id),
          set: [claimed_at: stale]
        )

      assert :processed = OperationWorker.run_once()

      operation = reload(Operation, operation.id)
      assert operation.state == "partially_succeeded"
      assert operation.error["code"] == "refs_diverged"
      assert show(path, ["rev-parse", "refs/heads/main"]) == diverged
      # The merged prefix stays landed underneath the diverged push.
      assert oids["layer-2"] ==
               show(path, ["rev-parse", operation.planned_result["trunk_new"] <> "^2"])
    end
  end

  ## Fixtures

  # main ── layer-1 ── layer-2 ── …, each layer adding one file.
  defp seed_stack(repository, actor, branches \\ ["layer-1", "layer-2"]) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    main = commit(path, nil, "Seed repository", %{"README.md" => "readme\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    {oids, _parent} =
      Enum.reduce(branches, {%{"main" => main}, main}, fn branch, {oids, parent} ->
        oid = commit(path, parent, "Layer #{branch}", %{"#{branch}.md" => "#{branch}\n"})
        {_, 0} = Repos.git(path, ["update-ref", "refs/heads/#{branch}", oid])
        {Map.put(oids, branch, oid), oid}
      end)

    pull_requests =
      branches
      |> Enum.with_index()
      |> Enum.map(fn {branch, index} ->
        base = Enum.at(["main" | branches], index)
        pull_request(repository, branch, base, oids[base], oids[branch])
      end)

    {:ok, stack} = Stacks.create(repository, pull_requests, actor)

    %{path: path, oids: oids, stack: stack, pull_requests: pull_requests}
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
    input_path = Path.join(System.tmp_dir!(), "merge-input-#{System.unique_integer([:positive])}")

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
