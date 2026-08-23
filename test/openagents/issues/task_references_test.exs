defmodule OpenAgents.Issues.TaskReferencesTest do
  @moduledoc """
  #12: a tracking issue's checkboxes follow the issues they point at.

  The concrete failure this closes: #6 was closed with a completion comment
  and the `- [ ] #6` checkbox in #9's delivery slice stayed unchecked until
  somebody edited it by hand. These tests hold both triggers — the fan-out
  when an issue's state moves, and the render every write goes through — and
  the boundaries around them.
  """

  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.Issues.{Comment, Issue, TaskReferences}
  alias OpenAgents.Repo

  setup do
    user = repository_user_fixture("tracker")
    repository = repository_with_member_fixture(user, %{}, "maintainer")
    {:ok, child} = Issues.create_issue(repository, %{title: "Read the legacy schema"})

    {:ok, parent} =
      Issues.create_issue(repository, %{
        title: "Port the forum",
        body: "Delivery slice:\n\n- [ ] ##{child.number} Read the legacy schema\n"
      })

    %{user: user, repository: repository, child: child, parent: parent}
  end

  defp close(issue, actor \\ nil),
    do: Issues.update_issue(issue, %{"state" => "closed", "state_reason" => "completed"}, actor)

  defp reopen(issue), do: Issues.update_issue(issue, %{"state" => "open"}, nil)

  defp body(%Issue{id: id}), do: Repo.get!(Issue, id).body
  defp body(%Comment{id: id}), do: Repo.get!(Comment, id).body

  describe "closing an issue" do
    test "checks every task-list box that points at it", context do
      %{child: child, parent: parent} = context

      {:ok, _closed} = close(child)

      assert body(parent) == "Delivery slice:\n\n- [x] ##{child.number} Read the legacy schema\n"
    end

    test "checks a box in a comment as well as in an issue body", context do
      %{repository: repository, child: child, parent: parent} = context

      {:ok, comment} =
        Issues.create_comment(parent, %{body: "Remaining:\n\n- [ ] ##{child.number}\n"})

      {:ok, _closed} = close(child)

      assert body(comment) == "Remaining:\n\n- [x] ##{child.number}\n"
      assert comment.repository_id == repository.id
    end

    test "records the edit as a system-attributed history entry", context do
      %{child: child, parent: parent} = context

      {:ok, _closed} = close(child)

      assert [sync] = TaskReferences.for_issue(parent)
      assert sync.principal == "system"
      assert sync.checked
      assert sync.reference_number == child.number
      assert sync.reference_issue_id == child.id
      assert sync.issue_id == parent.id
      assert is_nil(sync.comment_id)
    end

    test "attributes the edit to the system even when a person did the closing", context do
      %{user: user, child: child, parent: parent} = context

      {:ok, _closed} = close(child, user)

      assert [sync] = TaskReferences.for_issue(parent)
      assert sync.principal == "system"
      refute Map.has_key?(sync, :closed_by_user_id)
    end

    test "leaves a bare mention alone", context do
      %{repository: repository, child: child} = context

      {:ok, prose} =
        Issues.create_issue(repository, %{
          title: "Notes",
          body: "Blocked on ##{child.number} until the import lands."
        })

      {:ok, _closed} = close(child)

      assert body(prose) == "Blocked on ##{child.number} until the import lands."
      assert TaskReferences.for_issue(prose) == []
    end

    test "does not confuse #1 with #10", context do
      %{repository: repository} = context
      {:ok, first} = Issues.create_issue(repository, %{title: "First"})

      {:ok, tracker} =
        Issues.create_issue(repository, %{
          title: "Tracker",
          body: "- [ ] ##{first.number}0\n"
        })

      {:ok, _closed} = close(first)

      assert body(tracker) == "- [ ] ##{first.number}0\n"
    end
  end

  describe "reopening an issue" do
    test "restores the unchecked state", context do
      %{child: child, parent: parent} = context

      {:ok, closed} = close(child)
      assert body(parent) =~ "- [x] ##{child.number}"

      {:ok, _reopened} = reopen(closed)

      assert body(parent) == "Delivery slice:\n\n- [ ] ##{child.number} Read the legacy schema\n"
    end

    test "records a second history entry rather than deduplicating the first", context do
      %{child: child, parent: parent} = context

      {:ok, closed} = close(child)
      {:ok, _reopened} = reopen(closed)

      assert [checked, unchecked] = TaskReferences.for_issue(parent)
      assert checked.checked
      refute unchecked.checked
    end
  end

  describe "idempotence" do
    test "a second synchronize writes nothing and records nothing", context do
      %{child: child, parent: parent} = context

      {:ok, closed} = close(child)
      after_first = body(parent)

      :ok = TaskReferences.synchronize(%{closed | state: "open"}, closed)
      :ok = TaskReferences.synchronize(%{closed | state: "open"}, closed)

      assert body(parent) === after_first
      assert [_only_one] = TaskReferences.for_issue(parent)
    end

    test "a box already in the right state produces no entry", context do
      %{repository: repository, child: child} = context

      {:ok, closed} = close(child)

      {:ok, tracker} =
        Issues.create_issue(repository, %{
          title: "Written after the close",
          body: "- [x] ##{child.number}\n"
        })

      :ok = TaskReferences.synchronize(%{closed | state: "open"}, closed)

      assert body(tracker) == "- [x] ##{child.number}\n"
      assert TaskReferences.for_issue(tracker) == []
    end

    test "an update that does not move the state rewrites nothing", context do
      %{child: child, parent: parent} = context

      {:ok, _retitled} = Issues.update_issue(child, %{"title" => "Renamed"}, nil)

      assert body(parent) =~ "- [ ] ##{child.number}"
      assert TaskReferences.for_issue(parent) == []
    end
  end

  describe "rendering on write" do
    test "a new issue arrives already agreeing with the issues it names", context do
      %{repository: repository, child: child} = context

      {:ok, _closed} = close(child)

      {:ok, tracker} =
        Issues.create_issue(repository, %{
          title: "Opened after the close",
          body: "- [ ] ##{child.number}\n"
        })

      assert tracker.body == "- [x] ##{child.number}\n"
    end

    test "a person saving a stale body does not undo the automatic edit", context do
      %{child: child, parent: parent} = context

      {:ok, _closed} = close(child)

      # The body this edit carries is the one the author loaded before the
      # close, unchecked box and all. The render on write settles it.
      {:ok, saved} =
        Issues.update_issue(
          parent,
          %{"body" => "Delivery slice:\n\n- [ ] ##{child.number} Read the legacy schema\n"},
          nil
        )

      assert saved.body == "Delivery slice:\n\n- [x] ##{child.number} Read the legacy schema\n"
    end

    test "a new comment renders too", context do
      %{child: child, parent: parent} = context

      {:ok, _closed} = close(child)
      {:ok, comment} = Issues.create_comment(parent, %{body: "- [ ] ##{child.number}\n"})

      assert comment.body == "- [x] ##{child.number}\n"
    end

    test "an edited comment renders too", context do
      %{child: child, parent: parent} = context

      {:ok, comment} = Issues.create_comment(parent, %{body: "Nothing yet."})
      {:ok, _closed} = close(child)
      {:ok, edited} = Issues.update_comment(comment, %{body: "- [ ] ##{child.number}\n"})

      assert edited.body == "- [x] ##{child.number}\n"
    end
  end

  describe "boundaries" do
    test "a closed issue in one repository never rewrites another's body", context do
      %{child: child} = context
      other_user = repository_user_fixture("bystander")
      other = repository_with_member_fixture(other_user, %{}, "maintainer")

      {:ok, elsewhere} =
        Issues.create_issue(other, %{title: "Elsewhere", body: "- [ ] ##{child.number}\n"})

      {:ok, _closed} = close(child)

      assert body(elsewhere) == "- [ ] ##{child.number}\n"
      assert TaskReferences.for_issue(elsewhere) == []
    end

    test "a private repository's issue state cannot reach a public body", context do
      %{child: child} = context
      owner = repository_user_fixture("private-owner")
      private = repository_with_member_fixture(owner, %{visibility: "private"}, "maintainer")

      {:ok, secret} = Issues.create_issue(private, %{title: "Secret"})

      # Both repositories number from one, so the public body below says the
      # same `#N` the private issue answers to. If that ever stops being true
      # this assertion fails rather than letting the test pass vacuously.
      assert secret.number == child.number

      {:ok, public_tracker} =
        Issues.create_issue(child.repository_id |> repository!(), %{
          title: "Public tracker",
          body: "- [ ] ##{secret.number}\n"
        })

      before = body(public_tracker)
      {:ok, _closed} = close(secret)

      # The number resolves inside the public repository or not at all, so
      # nothing about the private issue reached the public body.
      assert body(public_tracker) === before
      assert TaskReferences.for_issue(public_tracker) == []

      # The same number binds to the public repository's own issue, which is
      # what makes the isolation a resolution rule rather than an accident.
      {:ok, _also_closed} = close(child)
      assert body(public_tracker) == "- [x] ##{child.number}\n"
    end

    test "a cross-repository reference is read and not acted on", context do
      %{repository: repository, child: child} = context

      {:ok, tracker} =
        Issues.create_issue(repository, %{
          title: "Cross",
          body: "- [ ] OpenAgentsInc/openagents.com##{child.number}\n"
        })

      {:ok, _closed} = close(child)

      assert body(tracker) == "- [ ] OpenAgentsInc/openagents.com##{child.number}\n"
    end
  end

  defp repository!(id), do: Repo.get!(OpenAgents.Repositories.Repository, id)
end
