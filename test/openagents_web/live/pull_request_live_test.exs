defmodule OpenAgentsWeb.PullRequestLiveTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest
  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks

  test "the pull request list links to a valid browser detail page", %{conn: conn} do
    target = repository_fixture()
    source = repository_fixture()
    issue = issue_fixture(target, %{title: "Add pull requests"})

    %PullRequest{}
    |> PullRequest.changeset(%{
      repository_id: target.id,
      issue_id: issue.id,
      head_repository_id: source.id,
      head_ref: "feature",
      head_sha: String.duplicate("a", 40),
      base_ref: "main",
      base_sha: String.duplicate("b", 40)
    })
    |> Repo.insert!()

    {:ok, index, _html} = live(conn, "/#{target.owner}/#{target.name}/pulls")
    assert has_element?(index, "#pull-request-index")

    assert has_element?(
             index,
             "a[href='/#{target.owner}/#{target.name}/pulls/#{issue.number}']"
           )

    {:ok, show, _html} =
      live(conn, "/#{target.owner}/#{target.name}/pulls/#{issue.number}")

    assert has_element?(show, "#pull-request-show")
  end

  describe "stacked pull request review" do
    setup do
      base =
        Path.join(
          System.tmp_dir!(),
          "pull-request-show-#{System.unique_integer([:positive])}"
        )

      previous_data = Application.get_env(:openagents, :forge_data_dir)
      previous_wal = Application.get_env(:openagents, :forge_wal_dir)
      Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
      Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

      on_exit(fn ->
        restore_env(:forge_data_dir, previous_data)
        restore_env(:forge_wal_dir, previous_wal)
        File.rm_rf(base)
      end)

      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])

      pull_requests = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      actor = repository_user_fixture("stack-reviewer")
      {:ok, _stack} = Stacks.create(repository, pull_requests, actor)

      %{repository: repository, oids: oids, pull_requests: pull_requests}
    end

    test "the layer diff runs from the boundary OID to the observed head OID", %{
      conn: conn,
      repository: repository,
      oids: oids,
      pull_requests: pull_requests
    } do
      top = Enum.at(pull_requests, 1)
      {:ok, show, html} = live(conn, pull_path(repository, top))

      assert has_element?(show, "#stack-review")

      assert element(show, "#stack-layer-range") |> render() =~
               "#{short(oids["layer-1"])} → #{short(oids["layer-2"])}"

      assert html =~ "layer-2.md"
      refute html =~ "layer-1.md"
      refute has_element?(show, "#stack-stale-boundary")
    end

    test "the cumulative preview runs from the trunk tip to the observed head OID", %{
      conn: conn,
      repository: repository,
      oids: oids,
      pull_requests: pull_requests
    } do
      top = Enum.at(pull_requests, 1)
      {:ok, show, html} = live(conn, pull_path(repository, top) <> "?view=cumulative")

      assert element(show, "#stack-cumulative-range") |> render() =~
               "Everything through position 2"

      assert element(show, "#stack-cumulative-range") |> render() =~
               "#{short(oids["main"])} → #{short(oids["layer-2"])}"

      assert html =~ "layer-1.md"
      assert html =~ "layer-2.md"
    end

    test "a parent rewrite shows the stale boundary state instead of lower layers", %{
      conn: conn,
      repository: repository,
      oids: oids,
      pull_requests: pull_requests
    } do
      path = Repos.bare_path(repository.storage_key)

      rewritten =
        commit(path, oids["main"], "Rewritten layer", ["README.md", "rewritten.md"])

      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/layer-1", rewritten])

      top = Enum.at(pull_requests, 1)
      {:ok, show, html} = live(conn, pull_path(repository, top))

      assert has_element?(show, "#stack-stale-boundary")
      assert has_element?(show, "#stack-restack-action")
      assert render(show) =~ "based on an outdated parent commit"
      refute html =~ "layer-1.md"
      refute html =~ "layer-2.md"
    end
  end

  defp pull_path(repository, pull_request) do
    "/#{repository.owner}/#{repository.name}/pulls/#{pull_request.issue.number}"
  end

  defp short(oid), do: String.slice(oid, 0, 12)

  defp seed_chain(repository, branches) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    main = commit(path, nil, "Seed repository", ["README.md"])
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    {oids, _files} =
      Enum.reduce(branches, {%{"main" => main}, ["README.md"]}, fn branch, {oids, files} ->
        parent = Map.fetch!(oids, previous_branch(branches, branch))
        files = files ++ ["#{branch}.md"]
        oid = commit(path, parent, "Layer #{branch}", files)
        {_, 0} = Repos.git(path, ["update-ref", "refs/heads/#{branch}", oid])
        {Map.put(oids, branch, oid), files}
      end)

    oids
  end

  defp previous_branch(branches, branch) do
    index = Enum.find_index(branches, &(&1 == branch))
    Enum.at(["main" | branches], index)
  end

  defp commit(path, parent, message, files) do
    tree_input =
      Enum.map_join(files, fn file ->
        blob = git!(path, ["hash-object", "-w", "--stdin"], "#{file}\n")
        "100644 blob #{blob}\t#{file}\n"
      end)

    tree = git!(path, ["mktree"], tree_input)
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

  defp pull_request_chain(repository, oids, branches) do
    branches
    |> Enum.with_index()
    |> Enum.map(fn {branch, index} ->
      base = Enum.at(["main" | branches], index)
      pull_request(repository, branch, base, oids[base], oids[branch])
    end)
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

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "pull-request-show-input-#{System.unique_integer([:positive])}"
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
