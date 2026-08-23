defmodule OpenAgents.Issues.ClosingReferencesTest do
  @moduledoc """
  #130: what a commit's closing reference is allowed to do to an issue.

  The push path calls `apply_commit/5` for commits newly reachable from the
  default branch. These are the rules it obeys once it gets there: same
  repository, write authority, once, never reopen.
  """

  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.Issues.ClosingReferences
  alias OpenAgents.Repo

  @sha "9606cbc0e0f1a2b3c4d5e6f708192a3b4c5d6e7f"

  setup do
    author = repository_user_fixture("pusher")
    repository = repository_with_member_fixture(author, %{}, "maintainer")
    {:ok, issue} = Issues.create_issue(repository, %{title: "Ship the closer"})

    %{author: author, repository: repository, issue: issue}
  end

  defp reload(issue), do: Repo.get!(OpenAgents.Issues.Issue, issue.id)

  describe "closing" do
    test "a Closes reference closes the issue and records the commit", context do
      %{author: author, repository: repository, issue: issue} = context
      message = "Ship it\n\nCloses ##{issue.number}\n"

      assert [reference] = ClosingReferences.apply_commit(repository, author, @sha, message)

      assert reference.commit_sha == @sha
      assert reference.closed
      assert reference.verb == "closes"
      assert reference.closed_by_user_id == author.id
      assert reload(issue).state == "closed"
      assert reload(issue).state_reason == "completed"
    end

    test "the close is attributed to the pushing principal, not a system actor", context do
      %{author: author, repository: repository, issue: issue} = context

      assert [reference] =
               ClosingReferences.apply_commit(
                 repository,
                 author,
                 @sha,
                 "Closes ##{issue.number}",
                 repo: "demo",
                 wal_seq: 3,
                 principal: "user:#{author.id}"
               )

      assert reference.principal == "user:#{author.id}"
      assert reference.closed_by_user_id == author.id
      assert reference.repo == "demo"
      assert reference.wal_seq == 3
    end

    test "Fixes and Resolves close the same way", context do
      %{author: author, repository: repository} = context
      {:ok, fixed} = Issues.create_issue(repository, %{title: "Fixed"})
      {:ok, resolved} = Issues.create_issue(repository, %{title: "Resolved"})

      ClosingReferences.apply_commit(repository, author, @sha, "Fixes ##{fixed.number}")

      ClosingReferences.apply_commit(
        repository,
        author,
        String.replace(@sha, "9", "a"),
        "Resolves ##{resolved.number}"
      )

      assert reload(fixed).state == "closed"
      assert reload(resolved).state == "closed"
    end

    test "a list closes every issue it names", context do
      %{author: author, repository: repository, issue: first} = context
      {:ok, second} = Issues.create_issue(repository, %{title: "Second"})

      message = "Ship both\n\nCloses ##{first.number}, ##{second.number}"

      assert [_one, _two] = ClosingReferences.apply_commit(repository, author, @sha, message)
      assert reload(first).state == "closed"
      assert reload(second).state == "closed"
    end
  end

  describe "what it refuses" do
    test "a pusher without write authority records nothing", context do
      %{repository: repository, issue: issue} = context
      outsider = repository_user_fixture("outsider")

      assert ClosingReferences.apply_commit(
               repository,
               outsider,
               @sha,
               "Closes ##{issue.number}"
             ) == []

      assert reload(issue).state == "open"
      assert ClosingReferences.for_issue(issue) == []
    end

    test "a read-only member records nothing", context do
      %{repository: repository, issue: issue} = context
      viewer = repository_user_fixture("viewer")
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository, viewer, "viewer")

      assert ClosingReferences.apply_commit(repository, viewer, @sha, "Closes ##{issue.number}") ==
               []

      assert reload(issue).state == "open"
    end

    test "a nonexistent issue number records nothing", context do
      %{author: author, repository: repository} = context

      assert ClosingReferences.apply_commit(repository, author, @sha, "Closes #99999") == []
    end

    test "an issue in another repository is not closed", context do
      %{author: author, repository: repository} = context
      elsewhere = repository_with_member_fixture(author, %{}, "maintainer")
      {:ok, foreign} = Issues.create_issue(elsewhere, %{title: "Not yours"})

      message = "Closes #{elsewhere.owner}/#{elsewhere.name}##{foreign.number}"

      assert ClosingReferences.apply_commit(repository, author, @sha, message) == []
      assert reload(foreign).state == "open"
    end

    test "a nil actor records nothing", context do
      %{repository: repository, issue: issue} = context

      assert ClosingReferences.apply_commit(repository, nil, @sha, "Closes ##{issue.number}") ==
               []

      assert reload(issue).state == "open"
    end

    test "a malformed reference records nothing and raises nothing", context do
      %{author: author, repository: repository, issue: issue} = context

      for message <- ["Closes #", "Closes #abc", "Closes", "", "Closes #0", nil, 42] do
        assert ClosingReferences.apply_commit(repository, author, @sha, message) == []
      end

      assert reload(issue).state == "open"
    end
  end

  describe "idempotency" do
    test "applying the same commit twice closes once and records one row", context do
      %{author: author, repository: repository, issue: issue} = context
      message = "Closes ##{issue.number}"

      assert [_recorded] = ClosingReferences.apply_commit(repository, author, @sha, message)
      assert ClosingReferences.apply_commit(repository, author, @sha, message) == []

      assert length(ClosingReferences.for_issue(issue)) == 1
    end

    test "an already-closed issue records the reference without reclosing", context do
      %{author: author, repository: repository, issue: issue} = context

      {:ok, closed} =
        Issues.update_issue(
          issue,
          %{"state" => "closed", "state_reason" => "not_planned"},
          author
        )

      assert [reference] =
               ClosingReferences.apply_commit(
                 repository,
                 author,
                 @sha,
                 "Closes ##{issue.number}"
               )

      refute reference.closed
      reloaded = reload(closed)
      assert reloaded.state == "closed"
      assert reloaded.state_reason == "not_planned"
    end

    test "a second commit referencing the same issue records its own row", context do
      %{author: author, repository: repository, issue: issue} = context
      other = String.replace(@sha, "9", "b")

      ClosingReferences.apply_commit(repository, author, @sha, "Closes ##{issue.number}")
      ClosingReferences.apply_commit(repository, author, other, "Closes ##{issue.number}")

      references = ClosingReferences.for_issue(issue)
      assert length(references) == 2
      assert Enum.count(references, & &1.closed) == 1
    end
  end

  describe "the derived blocked flag from #100" do
    test "closing through a commit unblocks a dependent", context do
      %{author: author, repository: repository, issue: prerequisite} = context
      {:ok, dependent} = Issues.create_issue(repository, %{title: "Waits on the closer"})

      assert :ok = Issues.add_dependencies(dependent, [prerequisite.number])
      assert %{blocked: true} = Issues.dependencies(dependent)

      ClosingReferences.apply_commit(
        repository,
        author,
        @sha,
        "Closes ##{prerequisite.number}"
      )

      assert %{blocked: false} = Issues.dependencies(dependent)

      assert Issues.list_issues(repository, blocked: true) == []
    end
  end

  describe "reading back" do
    test "for_commit/2 returns the references one commit made", context do
      %{author: author, repository: repository, issue: issue} = context

      ClosingReferences.apply_commit(repository, author, @sha, "Closes ##{issue.number}")

      assert [reference] = ClosingReferences.for_commit(repository, @sha)
      assert reference.issue.number == issue.number
      assert ClosingReferences.for_commit(repository, "0000000") == []
    end
  end
end
