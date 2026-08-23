defmodule OpenAgents.Forge.PushClosesIssuesTest do
  @moduledoc """
  #130, end to end over the real git client: a commit whose body says
  `Closes #N` closes issue N when it lands on the repository's default
  branch, and only then.

  Five issues shipped and stayed open until somebody closed them by hand —
  #112, #113, #114, #125, and #126 — and two of those carried a correctly
  formatted `Closes #N` line the forge read straight past. These tests are
  what stops that recurring.

  The guarantees they hold, in order of how expensive each is to lose:

    1. A malformed reference never fails a push.
    2. A topic branch closes nothing.
    3. Replay and re-push close once.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{CacheReadiness, Pushes}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.ClosingReferences
  alias OpenAgents.Repo

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "push-closes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    CacheReadiness.reset()

    user = repository_user_fixture("closer")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(user, %{name: "closes"}, "closes-demo")

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, _api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "Push closes test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      if previous_data,
        do: Application.put_env(:openagents, :forge_data_dir, previous_data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      if previous_wal,
        do: Application.put_env(:openagents, :forge_wal_dir, previous_wal),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      CacheReadiness.reset()
      File.rm_rf(base)
    end)

    work = seed_clone!(base, "http://x:#{plaintext}@127.0.0.1:#{port}/closer/closes.git")

    %{base: base, repository: repository, user: user, work: work}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp git!(dir, args) do
    {output, status} =
      System.cmd("git", ["-c", "credential.helper="] ++ args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp git(dir, args) do
    System.cmd("git", ["-c", "credential.helper="] ++ args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}]
    )
  end

  defp seed_clone!(base, url) do
    work = Path.join(base, "work")
    git!(base, ["clone", url, work])
    git!(work, ["config", "user.email", "closer@example.com"])
    git!(work, ["config", "user.name", "Closer"])
    # An empty clone leaves HEAD wherever the client's default points. Name
    # the branch the repository actually calls default so `checkout main`
    # later means what it says.
    git!(work, ["symbolic-ref", "HEAD", "refs/heads/main"])
    work
  end

  defp commit!(work, message) do
    name = "file-#{System.unique_integer([:positive])}.txt"
    File.write!(Path.join(work, name), message)
    git!(work, ["add", "-A"])
    git!(work, ["commit", "-m", message])
    work |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp reload(issue), do: Repo.get!(OpenAgents.Issues.Issue, issue.id)

  defp issue!(repository, title \\ "Ship the closer") do
    {:ok, issue} = Issues.create_issue(repository, %{title: title})
    issue
  end

  describe "the default branch" do
    test "a Closes line closes the issue and names the commit", context do
      %{repository: repository, work: work, user: user} = context
      issue = issue!(repository)

      sha = commit!(work, "Ship the closer\n\nCloses ##{issue.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      assert reload(issue).state == "closed"
      assert reload(issue).state_reason == "completed"

      assert [reference] = ClosingReferences.for_issue(issue)
      assert reference.commit_sha == sha
      assert reference.closed
      assert reference.closed_by_user_id == user.id
      assert reference.principal == "user:#{user.id}"
      assert is_integer(reference.wal_seq)
      assert is_binary(reference.push_receipt_id)
    end

    test "Fixes and Resolves behave the same, and a list closes both", context do
      %{repository: repository, work: work} = context
      first = issue!(repository, "First")
      second = issue!(repository, "Second")
      third = issue!(repository, "Third")

      commit!(work, "Fix two\n\nFixes ##{first.number}, ##{second.number}\n")
      commit!(work, "Resolve one\n\nResolves ##{third.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      assert reload(first).state == "closed"
      assert reload(second).state == "closed"
      assert reload(third).state == "closed"
    end

    test "a dependent stops being blocked, exactly as a manual close does", context do
      %{repository: repository, work: work} = context
      prerequisite = issue!(repository, "Prerequisite")
      dependent = issue!(repository, "Dependent")

      assert :ok = Issues.add_dependencies(dependent, [prerequisite.number])
      assert %{blocked: true} = Issues.dependencies(dependent)

      commit!(work, "Ship it\n\nCloses ##{prerequisite.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      assert %{blocked: false} = Issues.dependencies(dependent)
      assert Issues.list_issues(repository, blocked: true) == []
    end
  end

  describe "a branch that was never merged" do
    test "a topic branch closes nothing; merging to the default branch closes it", context do
      %{repository: repository, work: work} = context
      issue = issue!(repository)

      # main must exist before a topic branch can be merged into it.
      commit!(work, "Seed the default branch\n")
      git!(work, ["push", "origin", "HEAD:main"])

      git!(work, ["checkout", "-b", "topic"])
      commit!(work, "Ship the closer\n\nCloses ##{issue.number}\n")
      git!(work, ["push", "origin", "topic:refs/heads/topic"])

      assert reload(issue).state == "open"
      assert ClosingReferences.for_issue(issue) == []

      git!(work, ["checkout", "main"])
      git!(work, ["merge", "--no-ff", "-m", "Merge topic", "topic"])
      git!(work, ["push", "origin", "HEAD:main"])

      assert reload(issue).state == "closed"
      assert [_reference] = ClosingReferences.for_issue(issue)
    end
  end

  describe "a reference that cannot be acted on" do
    test "a malformed reference never fails the push", context do
      %{repository: repository, work: work} = context

      message = """
      Ship something odd

      Closes #
      Closes #abc
      Closes #0
      Closes #99999999999999999999
      Fixes #4242424
      Resolves SomeOther/repository#7
      """

      commit!(work, message)

      assert {_output, 0} = git(work, ["push", "origin", "HEAD:main"])

      # The push is durable: the receipt was written even though nothing in
      # the message resolved to an issue here.
      assert [%{wal_seq: 0}] = OpenAgents.Forge.recent_pushes(repository.storage_key)
    end

    test "the closing path cannot raise its way into a failed push", context do
      %{repository: repository} = context

      # Whatever shape the caller passes, the answer is `:ok`. This is the
      # guarantee that matters: the WAL has already acknowledged the push by
      # the time this runs, so refusing now would ask a client to retry a
      # push the forge has accepted.
      assert Pushes.close_referenced_issues(repository.storage_key, 0, :not_a_map, %{}, "user:x") ==
               :ok

      assert Pushes.close_referenced_issues("no-such-repo", 0, %{}, %{}, "user:x") == :ok
      assert Pushes.close_referenced_issues(repository.storage_key, 0, %{}, %{}, nil) == :ok
    end

    test "a push without a user principal records nothing", context do
      %{repository: repository, work: work} = context
      issue = issue!(repository)
      sha = commit!(work, "Ship it\n\nCloses ##{issue.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      # Wind the tracker back and replay the same commits under an operator
      # principal, the shape an automated push takes. There is no accountable
      # person behind the close, so nothing is recorded.
      Repo.delete_all(OpenAgents.Issues.ClosingReference)
      {:ok, _reopened} = Issues.update_issue(reload(issue), %{"state" => "open"}, nil)

      for principal <- ["operator", "machine:abc", "unauthenticated", "assignment:1"] do
        assert Pushes.close_referenced_issues(
                 repository.storage_key,
                 0,
                 %{},
                 %{"refs/heads/main" => sha},
                 principal
               ) == :ok
      end

      assert ClosingReferences.for_issue(issue) == []
      assert reload(issue).state == "open"
    end
  end

  describe "idempotency" do
    test "reconciling receipts closes nothing a second time", context do
      %{repository: repository, work: work} = context
      issue = issue!(repository)

      commit!(work, "Ship it\n\nCloses ##{issue.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      assert [reference] = ClosingReferences.for_issue(issue)

      # Reopen by hand, then replay. The reference is already recorded, so
      # replay must not close it again: a person's decision to reopen stands.
      {:ok, _reopened} = Issues.update_issue(reload(issue), %{"state" => "open"}, nil)

      Repo.delete_all(OpenAgents.Forge.PushReceipt)
      assert Pushes.reconcile_receipts(repository.storage_key) == 1

      assert reload(issue).state == "open"
      assert [replayed] = ClosingReferences.for_issue(issue)
      assert replayed.id == reference.id
      assert replayed.commit_sha == reference.commit_sha
    end

    test "a force push that re-presents the same commit closes once", context do
      %{repository: repository, work: work} = context
      issue = issue!(repository)

      commit!(work, "Seed\n")
      git!(work, ["push", "origin", "HEAD:main"])

      commit!(work, "Ship it\n\nCloses ##{issue.number}\n")
      git!(work, ["push", "origin", "HEAD:main"])

      assert reload(issue).state == "closed"
      assert length(ClosingReferences.for_issue(issue)) == 1

      # Rewind the branch and push the same tip again with force.
      git!(work, ["reset", "--hard", "HEAD~1"])
      git!(work, ["push", "--force", "origin", "HEAD:main"])
      git!(work, ["reset", "--hard", "ORIG_HEAD"])
      git!(work, ["push", "--force", "origin", "HEAD:main"])

      assert length(ClosingReferences.for_issue(issue)) == 1
    end
  end
end
