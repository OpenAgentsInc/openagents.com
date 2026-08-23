defmodule OpenAgents.Stacks.PolicyTest do
  @moduledoc """
  Effective-base policy evaluation (#52): every stacked pull request carries
  its direct base and its effective base (the stack trunk), and policy
  configuration such as `CODEOWNERS` resolves from the effective base tree —
  so an unmerged lower layer cannot weaken the rules an upper layer is held
  to.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Policy

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  setup do
    base = Path.join(System.tmp_dir!(), "stack-policy-#{System.unique_integer([:positive])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    actor = repository_user_fixture("policy-actor")
    repository = repository_with_member_fixture(actor)

    %{actor: actor, repository: repository}
  end

  test "an unstacked pull request evaluates its own base as both bases", context do
    %{repository: repository} = context

    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)
    main = commit(path, nil, "Seed", %{"README.md" => "readme\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])
    feature = commit(path, main, "Feature", %{"feature.md" => "feature\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/feature", feature])

    pull_request = pull_request(repository, "feature", "main", main, feature)

    assert {:ok, evaluation} = Policy.evaluation(repository, pull_request)
    assert evaluation.pull_request_id == pull_request.id
    assert evaluation.head_oid == feature
    assert evaluation.direct_base == %{ref: "main", oid: main}
    assert evaluation.effective_base == %{ref: "main", oid: main}
    assert evaluation.stack == nil
  end

  test "a stacked pull request carries the direct base and the trunk as effective base",
       context do
    %{repository: repository, actor: actor} = context

    %{oids: oids, stack: stack, pull_requests: [_pr_1, pr_2]} =
      seed_stack(repository, actor, %{"CODEOWNERS" => "* @trunk-owners\n"})

    assert {:ok, evaluation} = Policy.evaluation(repository, pr_2)
    assert evaluation.direct_base == %{ref: "layer-1", oid: oids["layer-1"]}
    assert evaluation.effective_base == %{ref: "main", oid: oids["main"]}

    assert evaluation.stack == %{
             id: stack.id,
             number: stack.number,
             position: 2,
             size: 2,
             health: "healthy"
           }
  end

  test "a lower layer editing CODEOWNERS does not weaken an upper layer's policy", context do
    %{repository: repository, actor: actor} = context

    # Layer 1 rewrites CODEOWNERS; layer 2 sits on top of it. Policy for
    # layer 2 must keep resolving CODEOWNERS from the trunk, not from the
    # unmerged layer-1 tree.
    %{path: path, oids: oids, pull_requests: [pr_1, pr_2]} =
      seed_stack(repository, actor, %{"CODEOWNERS" => "* @trunk-owners\n"},
        layer_1_files: %{"CODEOWNERS" => "* @weakened\n"}
      )

    assert {:ok, evaluation_1} = Policy.evaluation(repository, pr_1)
    assert {:ok, evaluation_2} = Policy.evaluation(repository, pr_2)

    for evaluation <- [evaluation_1, evaluation_2] do
      assert {:ok, codeowners} = Policy.codeowners(repository, evaluation)
      assert codeowners.path == "CODEOWNERS"
      assert codeowners.content == "* @trunk-owners\n"
      assert codeowners.source_oid == oids["main"]
    end

    # The direct parent's tree really does carry the weakened file — the
    # protection comes from evaluating at the effective base, not from the
    # file being absent.
    {weakened, 0} = Repos.git(path, ["show", "#{oids["layer-1"]}:CODEOWNERS"])
    assert weakened == "* @weakened\n"

    # Once the lower layer lands on the trunk, the effective base advances
    # and later evaluations legitimately see the new configuration.
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", oids["layer-1"]])
    sync_repository(repository)

    assert {:ok, landed} = Policy.evaluation(repository, pr_2)
    assert landed.effective_base == %{ref: "main", oid: oids["layer-1"]}
    assert {:ok, codeowners} = Policy.codeowners(repository, landed)
    assert codeowners.content == "* @weakened\n"
    assert codeowners.source_oid == oids["layer-1"]
  end

  defp seed_stack(repository, actor, trunk_files, options \\ []) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    main = commit(path, nil, "Seed repository", Map.put(trunk_files, "README.md", "readme\n"))
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    layer_1_files = Keyword.get(options, :layer_1_files, %{"layer-1.md" => "layer-1\n"})
    layer_1 = commit(path, main, "Layer 1", layer_1_files)
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", layer_1])

    layer_2 = commit(path, layer_1, "Layer 2", %{"layer-2.md" => "layer-2\n"})
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-2", layer_2])

    oids = %{"main" => main, "layer-1" => layer_1, "layer-2" => layer_2}

    pr_1 = pull_request(repository, "layer-1", "main", main, layer_1)
    pr_2 = pull_request(repository, "layer-2", "layer-1", layer_1, layer_2)

    {:ok, stack} = Stacks.create(repository, [pr_1, pr_2], actor)

    %{path: path, oids: oids, stack: stack, pull_requests: [pr_1, pr_2]}
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

  defp sync_repository(repository) do
    OpenAgents.Forge.Sync.ensure_fresh!(repository.storage_key, repository.default_branch)
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

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "stack-policy-input-#{System.unique_integer([:positive])}"
      )

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
