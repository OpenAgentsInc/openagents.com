defmodule OpenAgents.Stacks.ChecksTest do
  @moduledoc """
  Stack-aware checks (#53): full-context run identity, trunk-advance
  invalidation, immutable synthetic snapshot refs whose trees layer the
  current trunk plus every layer through the checked pull request, and
  every declared `run_on` policy.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.CheckRun
  alias OpenAgents.Stacks.Checks

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  setup do
    base = Path.join(System.tmp_dir!(), "stack-checks-#{System.unique_integer([:positive])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    actor = repository_user_fixture("checks-actor")
    repository = repository_with_member_fixture(actor)

    %{actor: actor, repository: repository}
  end

  describe "workflow definitions" do
    test "an absent definitions file returns no_workflows", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor, workflows: nil)

      assert {:error, :no_workflows} = Checks.plan(repository, stack)
    end

    test "a malformed definitions file is rejected", context do
      %{repository: repository, actor: actor} = context
      %{stack: stack} = seed_stack(repository, actor, workflows: "not json")

      assert {:error, {:invalid_workflows, :malformed_json}} = Checks.plan(repository, stack)
    end

    test "an unknown run_on policy is rejected", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack} =
        seed_stack(repository, actor,
          workflows: workflows_json([%{"name" => "unit", "run_on" => "sometimes"}])
        )

      assert {:error, {:invalid_workflows, {:unknown_run_on, "unit", "sometimes"}}} =
               Checks.plan(repository, stack)
    end
  end

  describe "run identity" do
    test "runs key to head, effective base, and workflow definition", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, oids: oids, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor, workflows: every_layer_workflows())

      {:ok, plan} = Checks.plan(repository, stack)

      assert plan.invalidated == 0
      assert plan.skipped == []
      assert length(plan.runs) == 2

      run_1 = Enum.find(plan.runs, &(&1.pull_request_id == pr_1.id))
      run_2 = Enum.find(plan.runs, &(&1.pull_request_id == pr_2.id))

      assert run_1.head_oid == oids["layer-1"]
      assert run_2.head_oid == oids["layer-2"]
      assert run_1.effective_base_oid == plan.trunk_oid
      assert run_2.effective_base_oid == plan.trunk_oid
      assert run_1.workflow_definition_oid == plan.definition_oid
      assert run_1.state == "pending"

      # A healthy stack's heads already contain every lower layer, so the
      # heads are their own snapshots and no synthetic ref publishes.
      assert run_1.tested_oid == oids["layer-1"]
      assert run_2.tested_oid == oids["layer-2"]
      assert is_nil(run_1.synthetic_ref)
      assert is_nil(run_2.synthetic_ref)
    end

    test "planning twice reuses runs instead of duplicating identity", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack} = seed_stack(repository, actor, workflows: every_layer_workflows())

      {:ok, first} = Checks.plan(repository, stack)
      {:ok, second} = Checks.plan(repository, stack)

      assert Enum.map(first.runs, & &1.id) |> Enum.sort() ==
               Enum.map(second.runs, & &1.id) |> Enum.sort()

      assert Repo.aggregate(CheckRun, :count) == 2
    end

    test "a trunk advance invalidates existing runs and re-keys new ones", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, path: path, oids: oids} =
        seed_stack(repository, actor, workflows: every_layer_workflows())

      {:ok, before_advance} = Checks.plan(repository, stack)
      old_trunk = before_advance.trunk_oid

      advance = commit(path, oids["main"], "Advance trunk", %{"advance.md" => "advance\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", advance])

      {:ok, after_advance} = Checks.plan(repository, stack)

      assert after_advance.trunk_oid == advance
      assert after_advance.invalidated == 2

      for run <- before_advance.runs do
        assert Repo.get!(CheckRun, run.id).state == "stale"
      end

      for run <- after_advance.runs do
        assert run.effective_base_oid == advance
        assert run.effective_base_oid != old_trunk
        assert run.state == "pending"
      end
    end

    test "refresh alone marks affected runs stale after a trunk advance", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, path: path, oids: oids} =
        seed_stack(repository, actor, workflows: every_layer_workflows())

      {:ok, plan} = Checks.plan(repository, stack)
      {:ok, run} = Checks.report(hd(plan.runs), "passed")
      assert run.state == "passed"

      advance = commit(path, oids["main"], "Advance trunk", %{"advance.md" => "advance\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", advance])

      {:ok, %{trunk_oid: ^advance, invalidated: 2}} = Checks.refresh(repository, stack)

      assert Repo.get!(CheckRun, run.id).state == "stale"
    end
  end

  describe "synthetic snapshot refs" do
    test "a stack behind trunk tests a synthetic snapshot of trunk plus its layers",
         context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, path: path, oids: oids, pull_requests: [pr_1, pr_2]} =
        seed_stack(repository, actor, workflows: every_layer_workflows())

      advance = commit(path, oids["main"], "Advance trunk", %{"advance.md" => "advance\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", advance])

      {:ok, plan} = Checks.plan(repository, stack)

      run_1 = Enum.find(plan.runs, &(&1.pull_request_id == pr_1.id))
      run_2 = Enum.find(plan.runs, &(&1.pull_request_id == pr_2.id))

      for run <- [run_1, run_2] do
        assert run.synthetic_ref == "refs/internal/checks/" <> run.id
        assert run.tested_oid != run.head_oid
        assert show(path, ["rev-parse", run.synthetic_ref]) == run.tested_oid
      end

      # The snapshot tree is the current trunk plus every layer through the
      # checked pull request.
      names_1 = tree_names(path, run_1.tested_oid)
      assert "advance.md" in names_1
      assert "layer-1.md" in names_1
      refute "layer-2.md" in names_1

      names_2 = tree_names(path, run_2.tested_oid)
      assert "advance.md" in names_2
      assert "layer-1.md" in names_2
      assert "layer-2.md" in names_2
    end

    test "a synthetic ref publishes once and never moves", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, path: path, oids: oids} =
        seed_stack(repository, actor, workflows: every_layer_workflows())

      advance = commit(path, oids["main"], "Advance trunk", %{"advance.md" => "advance\n"})
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", advance])

      {:ok, first} = Checks.plan(repository, stack)
      {:ok, second} = Checks.plan(repository, stack)

      assert Enum.map(first.runs, & &1.id) |> Enum.sort() ==
               Enum.map(second.runs, & &1.id) |> Enum.sort()

      for run <- second.runs do
        assert show(path, ["rev-parse", run.synthetic_ref]) == run.tested_oid
        assert Repo.get!(CheckRun, run.id).tested_oid == run.tested_oid
      end
    end
  end

  describe "run_on policies" do
    test "top_layer_only plans only the top layer, with explicit skips", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, pull_requests: [_pr_1, pr_2]} =
        seed_stack(repository, actor,
          workflows: workflows_json([%{"name" => "e2e", "run_on" => "top_layer_only"}])
        )

      {:ok, plan} = Checks.plan(repository, stack)

      assert [run] = plan.runs
      assert run.pull_request_id == pr_2.id
      assert plan.skipped == [%{position: 1, workflow: "e2e", policy: "top_layer_only"}]
    end

    test "bottom_layer_only plans only the bottom layer", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, pull_requests: [pr_1, _pr_2]} =
        seed_stack(repository, actor,
          workflows: workflows_json([%{"name" => "smoke", "run_on" => "bottom_layer_only"}])
        )

      {:ok, plan} = Checks.plan(repository, stack)

      assert [run] = plan.runs
      assert run.pull_request_id == pr_1.id
      assert plan.skipped == [%{position: 2, workflow: "smoke", policy: "bottom_layer_only"}]
    end

    test "changed_paths plans only layers that touch the declared paths", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack, pull_requests: [pr_1, _pr_2]} =
        seed_stack(repository, actor,
          workflows:
            workflows_json([
              %{
                "name" => "layer-1-only",
                "run_on" => "changed_paths",
                "paths" => ["layer-1.md"]
              }
            ])
        )

      {:ok, plan} = Checks.plan(repository, stack)

      assert [run] = plan.runs
      assert run.pull_request_id == pr_1.id

      assert plan.skipped == [
               %{position: 2, workflow: "layer-1-only", policy: "changed_paths"}
             ]
    end

    test "merge_group_only skips every layer outside a merge group", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack} =
        seed_stack(repository, actor,
          workflows:
            workflows_json([
              %{"name" => "queue-gate", "run_on" => "merge_group_only", "required" => true}
            ])
        )

      {:ok, plan} = Checks.plan(repository, stack)

      assert plan.runs == []

      assert plan.skipped == [
               %{position: 1, workflow: "queue-gate", policy: "merge_group_only"},
               %{position: 2, workflow: "queue-gate", policy: "merge_group_only"}
             ]
    end

    test "the merge_group context runs every workflow: required checks never skip",
         context do
      %{repository: repository, actor: actor} = context

      %{stack: stack} =
        seed_stack(repository, actor,
          workflows:
            workflows_json([
              %{"name" => "queue-gate", "run_on" => "merge_group_only", "required" => true},
              %{"name" => "e2e", "run_on" => "top_layer_only", "required" => true}
            ])
        )

      {:ok, plan} = Checks.plan(repository, stack, context: "merge_group")

      assert plan.skipped == []
      assert length(plan.runs) == 4
      assert Enum.all?(plan.runs, &(&1.context == "merge_group"))

      # Layer-context runs and merge-group runs have distinct identities.
      {:ok, layer_plan} = Checks.plan(repository, stack)
      assert [%{workflow_name: "e2e", context: "layer"}] = layer_plan.runs
    end
  end

  describe "reporting" do
    test "a pending run concludes once", context do
      %{repository: repository, actor: actor} = context

      %{stack: stack} = seed_stack(repository, actor, workflows: every_layer_workflows())

      {:ok, plan} = Checks.plan(repository, stack)
      [run | _rest] = plan.runs

      {:ok, passed} = Checks.report(run, "passed")
      assert passed.state == "passed"
      refute is_nil(passed.concluded_at)

      assert {:error, :not_pending} = Checks.report(passed, "failed")
    end
  end

  ## Seeding

  defp every_layer_workflows do
    workflows_json([%{"name" => "unit", "run_on" => "every_layer", "required" => true}])
  end

  defp workflows_json(workflows), do: Jason.encode!(%{"workflows" => workflows})

  defp seed_stack(repository, actor, opts) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)
    branches = ["layer-1", "layer-2"]

    seed = commit(path, nil, "Seed repository", %{"README.md" => "readme\n"})

    main =
      case Keyword.fetch!(opts, :workflows) do
        nil -> seed
        json -> commit_workflows(path, seed, json)
      end

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

  # Commits `.forge/workflows.json` as a nested tree over the parent's tree.
  defp commit_workflows(path, parent, json) do
    blob = git!(path, ["hash-object", "-w", "--stdin"], json)
    forge_tree = git!(path, ["mktree"], "100644 blob #{blob}\tworkflows.json\n")

    {listing, 0} = Repos.git(path, ["ls-tree", parent])

    entries =
      listing
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.ends_with?(&1, "\t.forge"))
      |> Enum.concat(["040000 tree #{forge_tree}\t.forge"])

    tree = git!(path, ["mktree"], Enum.map_join(entries, "", &(&1 <> "\n")))

    git!(path, ["commit-tree", tree, "-p", parent, "-m", "Declare workflows"], "",
      env: committer_env()
    )
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

    git!(path, ["commit-tree", tree] ++ parent_args ++ ["-m", message], "", env: committer_env())
  end

  defp committer_env do
    [
      {"GIT_AUTHOR_NAME", "Test Author"},
      {"GIT_AUTHOR_EMAIL", "author@example.test"},
      {"GIT_COMMITTER_NAME", "Test Author"},
      {"GIT_COMMITTER_EMAIL", "author@example.test"}
    ]
  end

  defp show(path, args) do
    {output, 0} = Repos.git(path, args)
    String.trim(output)
  end

  defp tree_names(path, commit_oid) do
    {listing, 0} = Repos.git(path, ["ls-tree", "-r", "--name-only", commit_oid])
    String.split(listing, "\n", trim: true)
  end

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(System.tmp_dir!(), "checks-input-#{System.unique_integer([:positive])}")

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
