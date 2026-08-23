defmodule OpenAgentsWeb.PullRequestLiveTest do
  use OpenAgentsWeb.ConnCase
  import Ecto.Query
  import Phoenix.LiveViewTest
  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry

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

  describe "telling pull requests apart from issues (#120)" do
    setup do
      target = repository_fixture()
      source = repository_fixture()

      plain = issue_fixture(target, %{title: "A plain issue"})
      proposal = issue_fixture(target, %{title: "A proposed change"})

      pull_request =
        %PullRequest{}
        |> PullRequest.changeset(%{
          repository_id: target.id,
          issue_id: proposal.id,
          head_repository_id: source.id,
          head_ref: "feature",
          head_sha: String.duplicate("a", 40),
          base_ref: "main",
          base_sha: String.duplicate("b", 40),
          draft: false
        })
        |> Repo.insert!()

      %{target: target, plain: plain, proposal: proposal, pull_request: pull_request}
    end

    test "the issue list no longer mixes pull requests in", %{
      conn: conn,
      target: target,
      plain: plain,
      proposal: proposal
    } do
      {:ok, index, _html} = live(conn, "/#{target.owner}/#{target.name}/issues")

      assert has_element?(
               index,
               "a[href='/#{target.owner}/#{target.name}/issues/#{plain.number}']"
             )

      refute has_element?(
               index,
               "a[href='/#{target.owner}/#{target.name}/issues/#{proposal.number}']"
             )
    end

    test "the pull request list draws the pull-request glyph, not an issue circle", %{
      conn: conn,
      target: target
    } do
      {:ok, index, _html} = live(conn, "/#{target.owner}/#{target.name}/pulls")

      assert has_element?(index, ".issue-status [data-icon='pull-request-open']")
      refute has_element?(index, ".issue-status [data-icon='octicon-issue-opened']")
    end

    test "the repository nav counts issues and pull requests apart", %{
      conn: conn,
      target: target
    } do
      {:ok, index, _html} = live(conn, "/#{target.owner}/#{target.name}/pulls")

      issues_count =
        index
        |> element("a[href='/#{target.owner}/#{target.name}/issues'] .repo-tabs__count")
        |> render()

      pulls_count =
        index
        |> element("a[href='/#{target.owner}/#{target.name}/pulls'] .repo-tabs__count")
        |> render()

      assert issues_count =~ ">1<"
      assert pulls_count =~ ">1<"
    end

    test "the pull request page states its own state as a glyph", %{
      conn: conn,
      target: target,
      proposal: proposal
    } do
      {:ok, show, _html} = live(conn, "/#{target.owner}/#{target.name}/pulls/#{proposal.number}")

      assert has_element?(show, "#pull-request-glyph[data-category='open']")
      assert has_element?(show, "#pull-request-state")
    end

    test "an issue page reached for a pull-request number says so and links to it", %{
      conn: conn,
      target: target,
      proposal: proposal
    } do
      {:ok, show, _html} = live(conn, "/#{target.owner}/#{target.name}/issues/#{proposal.number}")

      assert has_element?(show, "#issue-pull-request-state[data-category='open']")

      assert has_element?(
               show,
               "#issue-pull-request-link[href='/#{target.owner}/#{target.name}/pulls/#{proposal.number}']"
             )
    end

    test "a plain issue page keeps the issue glyph and offers no pull request", %{
      conn: conn,
      target: target,
      plain: plain
    } do
      {:ok, show, _html} = live(conn, "/#{target.owner}/#{target.name}/issues/#{plain.number}")

      refute has_element?(show, "#issue-pull-request-state")
      refute has_element?(show, "#issue-pull-request-link")
      assert has_element?(show, ".issue-heading__meta [data-icon='octicon-issue-opened']")
    end
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
      assert render(show) =~ "based on an outdated parent commit"
      refute html =~ "layer-1.md"
      refute html =~ "layer-2.md"
    end

    test "a reader sees the readiness summary and trunk link but no actions", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      top = Enum.at(pull_requests, 1)
      {:ok, show, _html} = live(conn, pull_path(repository, top))

      assert element(show, "#stack-readiness") |> render() =~
               "0 of 2 layers ready · 2 still in draft"

      assert has_element?(
               show,
               "#stack-map a[href='/#{repository.owner}/#{repository.name}/tree/main']"
             )

      refute has_element?(show, "#stack-rebase")
      refute has_element?(show, "#stack-unstack")
    end

    test "a writer starts a stack rebase from the page", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      conn = log_in_repository_user(conn, "stack-writer", repository)
      top = Enum.at(pull_requests, 1)
      {:ok, show, _html} = live(conn, pull_path(repository, top))

      show |> element("#stack-rebase") |> render_click()

      assert element(show, "#stack-operation-status") |> render() =~ "Stack rebase queued"

      assert Repo.exists?(
               from operation in OpenAgents.Stacks.Operation,
                 where: operation.kind == "rebase" and operation.state == "pending"
             )

      show |> element("#stack-rebase") |> render_click()
      assert element(show, "#stack-operation-status") |> render() =~ "Stack rebase queued"

      show |> element("#stack-operation-refresh") |> render_click()
      assert has_element?(show, "#stack-operation-status")
    end

    test "a writer removes the top layer from the stack", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      conn = log_in_repository_user(conn, "stack-writer", repository)
      [bottom, top] = pull_requests

      {:ok, bottom_show, _html} = live(conn, pull_path(repository, bottom))
      refute has_element?(bottom_show, "#stack-unstack")
      assert has_element?(bottom_show, "#stack-rebase")

      {:ok, show, _html} = live(conn, pull_path(repository, top))
      assert has_element?(show, "#stack-unstack")

      show |> element("#stack-unstack") |> render_click()

      assert render(show) =~ "The pull request left the stack."
      refute has_element?(show, "#stack-review")
    end

    test "a merged stack member keeps its stack map and shows the merged state", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      merge_stack!(pull_requests)
      [bottom, top] = pull_requests

      {:ok, show, _html} = live(conn, pull_path(repository, bottom))

      assert element(show, "#pull-request-state") |> render() =~ "merged"
      refute has_element?(show, "#stack-review")
      assert element(show, "#stack-history") |> render() =~ "layer 1 of 2"
      assert element(show, "#stack-history-note") |> render() =~ "merged into main"

      layers = element(show, "#stack-history-map") |> render()
      assert layers =~ ~s(data-state="merged")
      refute layers =~ ~s(data-state="open")

      assert has_element?(
               show,
               "#stack-history-map a[href='#{pull_path(repository, top)}']"
             )

      refute has_element?(show, "#stack-rebase")
      refute has_element?(show, "#stack-unstack")
    end

    test "a pull request closed without merging shows closed and no stack history", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      top = Enum.at(pull_requests, 1)

      {1, _rows} =
        Repo.update_all(
          from(entry in StackEntry, where: entry.pull_request_id == ^top.id),
          set: [removed_at: DateTime.utc_now()]
        )

      {1, _rows} =
        Repo.update_all(
          from(pr in PullRequest, where: pr.id == ^top.id),
          set: [state: "closed"]
        )

      {:ok, show, _html} = live(conn, pull_path(repository, top))

      assert element(show, "#pull-request-state") |> render() =~ "closed"
      refute has_element?(show, "#stack-review")
      refute has_element?(show, "#stack-history")
    end

    test "the pull request list shows the merged state", %{
      conn: conn,
      repository: repository,
      pull_requests: pull_requests
    } do
      merge_stack!(pull_requests)

      {:ok, index, _html} = live(conn, "/#{repository.owner}/#{repository.name}/pulls")

      assert has_element?(index, "span[data-variant='done']", "merged")
    end
  end

  # Marks every layer merged the way `Merge.execute/2` records it: the entry
  # removal and the pull request merge share one timestamp, and the stack
  # completes.
  defp merge_stack!(pull_requests) do
    now = DateTime.utc_now()
    ids = Enum.map(pull_requests, & &1.id)

    {_count, _rows} =
      Repo.update_all(
        from(entry in StackEntry, where: entry.pull_request_id in ^ids),
        set: [removed_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(pr in PullRequest, where: pr.id in ^ids),
        set: [state: "closed", merged_at: now]
      )

    {_count, _rows} = Repo.update_all(Stack, set: [state: "completed"])

    :ok
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
