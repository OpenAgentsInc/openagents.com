defmodule OpenAgents.Issues.ReleasesTest do
  @moduledoc """
  #10, the half of the traceability chain a sha comparison cannot answer.

  An issue's closing commit is an ancestor of the revision a release was
  promoted at, never that revision itself, so `OpenAgents.Forge.receipts_for/2`
  — which matches a fleet target by comparing shas — finds nothing for the
  commit that actually shipped. These tests run against a real bare forge
  repository with a real commit graph and real promoted targets, because the
  only thing that makes the answer true is git's own containment relation.

  The graph every test reads:

      c0 ── c1 ── c2 ── c3      (refs/heads/main = c3)
        └── side                (refs/heads/side, never merged)
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{Activity, ClosingReference, Releases}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  @repo "openagents.com"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "issue-releases-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore(:forge_data_dir, previous_data)
      restore(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    repository = Repositories.get_by_path!("OpenAgentsInc", @repo)
    {:ok, issue} = Issues.create_issue(repository, %{title: "Ship the release link"})

    Map.merge(seed_graph(), %{repository: repository, issue: issue})
  end

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  describe "for_issue/2" do
    test "an issue no commit claims has no commits and no release", context do
      assert Releases.for_issue(context.repository, context.issue) == Releases.empty()
    end

    test "a release promoted at a descendant of the issue's commit carried it", context do
      claim(context, context.c1)
      target = release(context.c2, "live")

      assert %{commits: [commit], released_in: released, truncated: false} =
               Releases.for_issue(context.repository, context.issue)

      assert commit.sha == context.c1
      assert [carried] = commit.releases
      assert carried.sha == context.c2
      assert carried.status == "live"
      assert released.id == target.id
      assert released.sha == context.c2
    end

    test "a release promoted before the commit existed did not carry it", context do
      claim(context, context.c2)
      release(context.c0, "live")

      assert %{commits: [commit], released_in: nil} =
               Releases.for_issue(context.repository, context.issue)

      assert commit.releases == []
    end

    test "a commit that never reached the mainline is carried by nothing", context do
      claim(context, context.side)
      release(context.c3, "live")

      assert %{commits: [commit], released_in: nil} =
               Releases.for_issue(context.repository, context.issue)

      assert commit.releases == []
    end

    test "every release that contains the commit is listed, oldest first", context do
      claim(context, context.c1)
      first = release(context.c2, "live")
      second = release(context.c3, "live")

      assert %{commits: [commit], released_in: released} =
               Releases.for_issue(context.repository, context.issue)

      assert Enum.map(commit.releases, & &1.id) == [first.id, second.id]
      assert released.id == first.id
    end

    test "released_in is the oldest live release that carried every commit", context do
      claim(context, context.c1)
      claim(context, context.c3)
      partial = release(context.c2, "live")
      whole = release(context.c3, "live")

      assert %{commits: commits, released_in: released} =
               Releases.for_issue(context.repository, context.issue)

      by_sha = Map.new(commits, &{&1.sha, &1})

      assert Enum.map(by_sha[context.c1].releases, & &1.id) == [partial.id, whole.id]
      assert Enum.map(by_sha[context.c3].releases, & &1.id) == [whole.id]
      assert released.id == whole.id
    end

    test "a promoted release that never went live is listed but never released_in", context do
      claim(context, context.c1)
      promoted = release(context.c3, "promoted")

      assert %{commits: [commit], released_in: nil} =
               Releases.for_issue(context.repository, context.issue)

      assert [carried] = commit.releases
      assert carried.id == promoted.id
      assert carried.status == "promoted"
    end

    test "the target window is bounded and says so when it cuts something off", context do
      claim(context, context.c1)
      for _each <- 1..13, do: release(context.c3, "live")

      assert %{commits: [commit], truncated: true} =
               Releases.for_issue(context.repository, context.issue)

      assert length(commit.releases) == 12
    end

    test "a repository that is not the issue's own answers with nothing", context do
      claim(context, context.c1)
      release(context.c2, "live")

      other = %{context.repository | id: Ecto.UUID.generate()}

      assert Releases.for_issue(other, context.issue) == Releases.empty()
    end
  end

  describe "the activity read and its JSON" do
    test "activity carries the release that shipped the issue", context do
      claim(context, context.c1)
      target = release(context.c2, "live")

      activity = Activity.for_issue(context.issue)

      assert activity.releases.released_in.id == target.id

      rendered = OpenAgentsWeb.IssueJSON.render("activity.json", %{activity: activity})

      assert %{released_in: %{sha: sha, status: "live"}, truncated: false} = rendered.releases
      assert sha == context.c2
      assert [%{sha: ^sha}] = hd(rendered.releases.commits).releases
    end

    test "an issue nothing shipped renders an empty release answer", context do
      rendered =
        OpenAgentsWeb.IssueJSON.render("activity.json", %{
          activity: Activity.for_issue(context.issue)
        })

      assert rendered.releases == %{commits: [], released_in: nil, truncated: false}
    end
  end

  # ── fixture ──────────────────────────────────────────────────────────────

  # One `Closes #N` reference, written the way `OpenAgents.Issues.ClosingReferences`
  # writes it. What the reference means is proved by `OpenAgents.Forge.PushClosesIssuesTest`;
  # what it is worth here is the commit it names.
  defp claim(%{repository: repository, issue: issue}, sha) do
    %ClosingReference{}
    |> ClosingReference.changeset(%{
      repository_id: repository.id,
      issue_id: issue.id,
      commit_sha: sha,
      repo: @repo,
      principal: "test:releases",
      verb: "closes",
      closed: true
    })
    |> Repo.insert!()
  end

  # One promotion through the real lane, so the sha precondition and the
  # transition table both run. `status` is where the target is left.
  defp release(sha, status) do
    {:ok, target} = Targets.promote(@repo, sha, "operator:releases-test")

    Enum.reduce_while(["building", "built", "deploying", "live"], target, fn step, current ->
      if current.status == status, do: {:halt, current}, else: {:cont, advance(current, step)}
    end)
  end

  defp advance(target, step) do
    {:ok, advanced} = Targets.advance(target.id, step)
    advanced
  end

  defp seed_graph do
    path = Repos.ensure_repo!(@repo)

    c0 = commit(path, [{"f.txt", "zero\n"}], [])
    c1 = commit(path, [{"f.txt", "zero\n"}, {"one.txt", "one\n"}], ["-p", c0])
    c2 = commit(path, [{"f.txt", "zero\n"}, {"two.txt", "two\n"}], ["-p", c1])
    c3 = commit(path, [{"f.txt", "zero\n"}, {"three.txt", "three\n"}], ["-p", c2])
    side = commit(path, [{"f.txt", "zero\n"}, {"side.txt", "side\n"}], ["-p", c0])

    {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", c3])
    {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/side", side])

    %{path: path, c0: c0, c1: c1, c2: c2, c3: c3, side: side}
  end

  defp commit(path, files, parents) do
    listing =
      files
      |> Enum.map(fn {name, content} -> "100644 blob #{blob(path, content)}\t#{name}\n" end)
      |> Enum.join()

    {tree, 0} = plumb(path, ["mktree"], listing)

    {sha, 0} =
      plumb(path, ["commit-tree", String.trim(tree)] ++ parents, "commit #{listing}",
        env: [
          {"GIT_AUTHOR_NAME", "Release Test"},
          {"GIT_AUTHOR_EMAIL", "release@example.test"},
          {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
          {"GIT_COMMITTER_NAME", "Release Test"},
          {"GIT_COMMITTER_EMAIL", "release@example.test"},
          {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
        ]
      )

    String.trim(sha)
  end

  defp blob(path, content) do
    {sha, 0} = plumb(path, ["hash-object", "-w", "--stdin"], content)
    String.trim(sha)
  end

  defp plumb(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "plumb-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(opts, :env, [])
      )
    after
      File.rm(input)
    end
  end
end
