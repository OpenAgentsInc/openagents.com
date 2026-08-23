defmodule OpenAgents.IssuesTest do
  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.Issue

  defmodule AnalyticsSink do
    def capture(event, distinct_id, properties) do
      send(Application.fetch_env!(:openagents, :issues_analytics_test_pid), {
        :captured,
        event,
        distinct_id,
        properties
      })
    end
  end

  setup do
    repository = repository_fixture()

    Enum.each(~w(alice bob carol), fn login ->
      user = repository_user_fixture(login)
      {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "contributor")
    end)

    Process.put({__MODULE__, :repository}, repository)
    on_exit(fn -> Process.delete({__MODULE__, :repository}) end)
    :ok
  end

  defp backdate!(%Issue{} = issue, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

    {1, nil} =
      Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [inserted_at: at])

    Issues.get_issue!(repository(), issue.id)
  end

  describe "triage analytics" do
    setup do
      original_token = Application.get_env(:openagents, :posthog_project_token)
      original_sink = Application.get_env(:openagents, :analytics_sink)
      original_pid = Application.get_env(:openagents, :issues_analytics_test_pid)

      Application.put_env(:openagents, :posthog_project_token, "phc_test")
      Application.put_env(:openagents, :analytics_sink, AnalyticsSink)
      Application.put_env(:openagents, :issues_analytics_test_pid, self())

      on_exit(fn ->
        restore_env(:posthog_project_token, original_token)
        restore_env(:analytics_sink, original_sink)
        restore_env(:issues_analytics_test_pid, original_pid)
      end)

      maintainer = repository_user_fixture("triage-maintainer")

      {:ok, _membership} =
        OpenAgents.Repositories.add_member(repository(), maintainer, "maintainer")

      %{maintainer: maintainer}
    end

    test "issue creation carries stable issue and label state", %{maintainer: maintainer} do
      assert {:ok, issue} =
               Issues.create_issue(repository(), %{title: "Measure triage"}, maintainer)

      assert_receive {:captured, "issue_created", _distinct_id, properties}
      assert properties["owner"] == repository().owner
      assert properties["repo"] == repository().name
      assert properties["issue_number"] == issue.number
      assert properties["issue_state"] == "open"
      assert properties["has_labels"] == false
    end

    test "issue updates identify real state transitions", %{maintainer: maintainer} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Close me"}, maintainer)
      assert_receive {:captured, "issue_created", _, _}

      assert {:ok, _closed} =
               Issues.update_issue(issue, %{"state" => "closed"}, maintainer)

      assert_receive {:captured, "issue_updated", _distinct_id, properties}
      assert properties["issue_number"] == issue.number
      assert properties["previous_issue_state"] == "open"
      assert properties["issue_state"] == "closed"
      assert properties["issue_state_changed"] == true
      assert properties["has_labels"] == false
    end

    test "comments record whether the author is a maintainer", %{maintainer: maintainer} do
      {:ok, issue} = Issues.create_issue(repository(), %{title: "Respond to me"}, maintainer)
      assert_receive {:captured, "issue_created", _, _}

      assert {:ok, _comment} =
               Issues.create_comment(issue, %{body: "Acknowledged"}, maintainer)

      assert_receive {:captured, "issue_commented", _distinct_id, properties}
      assert properties["owner"] == repository().owner
      assert properties["repo"] == repository().name
      assert properties["issue_number"] == issue.number
      assert properties["author_role"] == "maintainer"
      assert properties["is_maintainer"] == true
    end
  end

  describe "list_issues/1" do
    test "returns only open issues by default" do
      open = issue_fixture(title: "open one")
      closed = issue_fixture(title: "closed one")
      {:ok, closed} = Issues.update_issue(closed, %{"state" => "closed"})

      numbers = Issues.list_issues(repository()) |> Enum.map(& &1.number)

      assert open.number in numbers
      refute closed.number in numbers
    end

    test "filters by an explicit state" do
      _open = issue_fixture(title: "open one")
      closed = issue_fixture(title: "closed one")
      {:ok, closed} = Issues.update_issue(closed, %{"state" => "closed"})

      assert Issues.list_issues(repository(), state: "closed") |> Enum.map(& &1.number) == [
               closed.number
             ]
    end

    test "state: \"all\" skips the filter" do
      open = issue_fixture(title: "open one")
      closed = issue_fixture(title: "closed one")
      {:ok, _} = Issues.update_issue(closed, %{"state" => "closed"})

      numbers =
        Issues.list_issues(repository(), state: "all") |> Enum.map(& &1.number) |> Enum.sort()

      assert numbers == Enum.sort([open.number, closed.number])
    end

    test "returns an empty list when nothing matches" do
      assert Issues.list_issues(repository()) == []
      assert Issues.list_issues(repository(), state: "all") == []
    end

    test "orders newest first" do
      oldest = issue_fixture(title: "oldest") |> backdate!(300)
      middle = issue_fixture(title: "middle") |> backdate!(200)
      newest = issue_fixture(title: "newest") |> backdate!(100)

      assert Issues.list_issues(repository()) |> Enum.map(& &1.id) == [
               newest.id,
               middle.id,
               oldest.id
             ]
    end
  end

  describe "get_issue!/1 and get_issue_by_number!/1" do
    test "get_issue!/1 returns the issue with the given id" do
      issue = issue_fixture()
      assert Issues.get_issue!(repository(), issue.id) == issue
    end

    test "get_issue!/1 raises for an unknown id" do
      issue = issue_fixture()
      assert_raise Ecto.NoResultsError, fn -> Issues.get_issue!(repository(), issue.id + 1) end
    end

    test "get_issue_by_number!/1 returns the issue with the given number" do
      issue = issue_fixture()
      assert Issues.get_issue_by_number!(repository(), issue.number) == issue
    end

    test "get_issue_by_number!/1 raises for an unknown number" do
      issue = issue_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue_by_number!(repository(), issue.number + 1)
      end
    end
  end

  describe "create_issue/1" do
    test "assigns numbers from one upwards" do
      assert {:ok, %Issue{number: 1}} = Issues.create_issue(repository(), %{title: "one"})
      assert {:ok, %Issue{number: 2}} = Issues.create_issue(repository(), %{title: "two"})
      assert {:ok, %Issue{number: 3}} = Issues.create_issue(repository(), %{title: "three"})
    end

    test "ignores a caller-supplied number" do
      assert {:ok, %Issue{number: 1}} =
               Issues.create_issue(repository(), %{title: "one", number: 99})
    end

    test "sets the documented defaults" do
      assert {:ok, %Issue{} = issue} = Issues.create_issue(repository(), %{title: "defaults"})

      assert issue.state == "open"
      assert issue.locked == false
      assert issue.comments == 0
      assert issue.labels == []
      assert issue.assignees == []
      assert is_nil(issue.milestone)
      assert is_nil(issue.closed_at)
    end

    test "accepts string keys" do
      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{"title" => "strings", "body" => "hello"})

      assert issue.title == "strings"
      assert issue.body == "hello"
    end

    test "requires a title" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Issues.create_issue(repository(), %{body: "no title"})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "called with no attrs at all it still refuses" do
      assert {:error, %Ecto.Changeset{} = changeset} = Issues.create_issue(repository(), %{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "expands known label names into label maps" do
      label = label_fixture(name: "bug", color: "d73a4a", description: "Something broken")

      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{title: "labelled", labels: ["bug"]})

      assert issue.labels == [
               %{
                 "id" => label.id,
                 "name" => "bug",
                 "color" => "d73a4a",
                 "description" => "Something broken"
               }
             ]
    end

    test "rejects a label outside the repository label set" do
      assert_raise Ecto.NoResultsError, fn ->
        Issues.create_issue(repository(), %{title: "labelled", labels: ["nope"]})
      end
    end

    test "canonicalizes label maps from the repository row" do
      label = label_fixture(name: "bug", color: "abcdef")
      given = [%{"name" => "bug", "color" => "abcdef"}]

      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{title: "labelled", labels: given})

      assert issue.labels == [
               %{
                 "id" => label.id,
                 "name" => "bug",
                 "color" => "abcdef",
                 "description" => label.description
               }
             ]
    end

    test "accepts an empty label list" do
      assert {:ok, %Issue{labels: []}} =
               Issues.create_issue(repository(), %{title: "none", labels: []})
    end

    test "expands assignee logins into assignee maps" do
      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{title: "assigned", assignees: ["alice", "bob"]})

      assert issue.assignees == [%{"login" => "alice"}, %{"login" => "bob"}]
    end

    test "canonicalizes assignee maps from repository membership" do
      given = [%{"login" => "alice", "id" => 7}]

      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{title: "assigned", assignees: given})

      assert issue.assignees == [%{"login" => "alice"}]
    end

    test "expands a milestone number into a milestone map" do
      milestone = milestone_fixture(title: "v1", state: "open", due_on: "2026-01-01")

      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(repository(), %{title: "planned", milestone: milestone.number})

      assert issue.milestone == %{
               "number" => milestone.number,
               "title" => "v1",
               "state" => "open",
               "description" => milestone.description,
               "due_on" => "2026-01-01"
             }
    end

    test "raises for an unknown milestone number" do
      assert_raise Ecto.NoResultsError, fn ->
        Issues.create_issue(repository(), %{title: "planned", milestone: 404})
      end
    end

    test "accepts an explicit nil milestone" do
      assert {:ok, %Issue{milestone: nil}} =
               Issues.create_issue(repository(), %{title: "unplanned", milestone: nil})
    end
  end

  describe "update_issue/2" do
    test "updates plain fields" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = updated} =
               Issues.update_issue(issue, %{"title" => "new title", "body" => "new body"})

      assert updated.title == "new title"
      assert updated.body == "new body"
    end

    test "returns an error changeset for invalid data" do
      issue = issue_fixture()

      assert {:error, %Ecto.Changeset{}} = Issues.update_issue(issue, %{"title" => nil})
      assert issue == Issues.get_issue!(repository(), issue.id)
    end

    test "closing stamps closed_at and defaults the state reason" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = closed} = Issues.update_issue(issue, %{"state" => "closed"})

      assert closed.state == "closed"
      assert closed.state_reason == "completed"
      refute is_nil(closed.closed_at)
    end

    test "closing keeps an explicit state reason" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = closed} =
               Issues.update_issue(issue, %{
                 "state" => "closed",
                 "state_reason" => "not_planned"
               })

      assert closed.state_reason == "not_planned"
    end

    test "closing an already-closed issue does not re-stamp closed_at" do
      issue = issue_fixture()
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"})

      assert {:ok, %Issue{} = again} =
               Issues.update_issue(closed, %{"state" => "closed", "title" => "still closed"})

      assert again.closed_at == closed.closed_at
      assert again.title == "still closed"
    end

    test "reopening clears closed_at and the state reason" do
      issue = issue_fixture()
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"})

      assert {:ok, %Issue{} = reopened} = Issues.update_issue(closed, %{"state" => "open"})

      assert reopened.state == "open"
      assert is_nil(reopened.closed_at)
      assert is_nil(reopened.state_reason)
    end

    test "closing works with atom keys too" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = closed} = Issues.update_issue(issue, %{state: "closed"})

      assert closed.state == "closed"
      assert closed.state_reason == "completed"
      refute is_nil(closed.closed_at)
    end

    test "closing with atom keys keeps a caller-supplied closed_at" do
      issue = issue_fixture()
      at = ~U[2026-01-01 00:00:00Z]

      assert {:ok, %Issue{} = closed} =
               Issues.update_issue(issue, %{state: "closed", closed_at: at})

      assert closed.closed_at == at
    end

    test "reopening works with atom keys too" do
      issue = issue_fixture()
      {:ok, closed} = Issues.update_issue(issue, %{state: "closed"})

      assert {:ok, %Issue{} = reopened} = Issues.update_issue(closed, %{state: "open"})

      assert is_nil(reopened.closed_at)
      assert is_nil(reopened.state_reason)
    end

    test "locking an issue is a plain field update" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = locked} =
               Issues.update_issue(issue, %{"locked" => true, "locked_reason" => "spam"})

      assert locked.locked
      assert locked.locked_reason == "spam"
    end
  end

  describe "change_issue/2" do
    test "returns a changeset" do
      issue = issue_fixture()
      assert %Ecto.Changeset{} = Issues.change_issue(issue)
    end

    test "applies attrs and surfaces validation errors" do
      issue = issue_fixture()

      assert Issues.change_issue(issue, %{title: "Renamed"}).valid?

      changeset = Issues.change_issue(issue, %{title: nil})
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "labels on an issue" do
    test "add_labels/2 appends known labels" do
      label_fixture(name: "bug", color: "d73a4a")
      issue = issue_fixture()

      assert {:ok, %Issue{} = updated} = Issues.add_labels(issue, ["bug"])
      assert Enum.map(updated.labels, & &1["name"]) == ["bug"]
      assert hd(updated.labels)["color"] == "d73a4a"
    end

    test "add_labels/2 does not duplicate an existing label" do
      label_fixture(name: "bug", color: "d73a4a")
      issue = issue_fixture()

      {:ok, issue} = Issues.add_labels(issue, ["bug"])
      assert {:ok, %Issue{} = updated} = Issues.add_labels(issue, ["bug"])

      assert Enum.map(updated.labels, & &1["name"]) == ["bug"]
    end

    test "add_labels/2 accepts several names at once" do
      label_fixture(name: "bug", color: "d73a4a")
      label_fixture(name: "docs", color: "0075ca")
      issue = issue_fixture()

      assert {:ok, %Issue{} = updated} = Issues.add_labels(issue, ["bug", "docs"])
      assert Enum.map(updated.labels, & &1["name"]) == ["bug", "docs"]
    end

    # GitHub creates a label on the fly when one is added that does not
    # exist, and so do we: the name is scoped to this repository either way.
    test "add_labels/2 creates an unknown label instead of raising" do
      issue = issue_fixture()

      assert {:ok, %Issue{labels: [label]}} = Issues.add_labels(issue, ["nope"])
      assert label["name"] == "nope"

      assert %{color: color} =
               OpenAgents.Labels.get_label_by_name!(
                 repository(),
                 "nope"
               )

      refute color in ["", nil]
    end

    test "add_labels/2 with an empty list is a no-op" do
      issue = issue_fixture()
      assert {:ok, %Issue{labels: []}} = Issues.add_labels(issue, [])
    end

    test "remove_label/2 drops the named label" do
      label_fixture(name: "bug", color: "d73a4a")
      label_fixture(name: "docs", color: "0075ca")
      issue = issue_fixture()
      {:ok, issue} = Issues.add_labels(issue, ["bug", "docs"])

      assert {:ok, %Issue{} = updated} = Issues.remove_label(issue, "bug")
      assert Enum.map(updated.labels, & &1["name"]) == ["docs"]
    end

    test "remove_label/2 decodes a percent-encoded name" do
      label_fixture(name: "help wanted", color: "008672")
      issue = issue_fixture()
      {:ok, issue} = Issues.add_labels(issue, ["help wanted"])

      assert {:ok, %Issue{labels: []}} = Issues.remove_label(issue, "help%20wanted")
    end

    test "remove_label/2 is a no-op for a label the issue does not carry" do
      label_fixture(name: "bug", color: "d73a4a")
      issue = issue_fixture()
      {:ok, issue} = Issues.add_labels(issue, ["bug"])

      assert {:ok, %Issue{} = updated} = Issues.remove_label(issue, "docs")
      assert Enum.map(updated.labels, & &1["name"]) == ["bug"]
    end

    test "remove_label/2 tolerates an issue with no labels" do
      issue = issue_fixture()
      assert {:ok, %Issue{labels: []}} = Issues.remove_label(issue, "bug")
    end
  end

  describe "assignees on an issue" do
    test "add_assignees/2 appends logins" do
      issue = issue_fixture()

      assert {:ok, %Issue{} = updated} = Issues.add_assignees(issue, ["alice", "bob"])
      assert updated.assignees == [%{"login" => "alice"}, %{"login" => "bob"}]
    end

    test "add_assignees/2 does not duplicate an existing login" do
      issue = issue_fixture()
      {:ok, issue} = Issues.add_assignees(issue, ["alice"])

      assert {:ok, %Issue{} = updated} = Issues.add_assignees(issue, ["alice", "bob"])
      assert updated.assignees == [%{"login" => "alice"}, %{"login" => "bob"}]
    end

    test "remove_assignees/2 drops the named logins" do
      issue = issue_fixture()
      {:ok, issue} = Issues.add_assignees(issue, ["alice", "bob", "carol"])

      assert {:ok, %Issue{} = updated} = Issues.remove_assignees(issue, ["alice", "carol"])
      assert updated.assignees == [%{"login" => "bob"}]
    end

    test "remove_assignees/2 ignores logins the issue does not carry" do
      issue = issue_fixture()
      {:ok, issue} = Issues.add_assignees(issue, ["alice"])

      assert {:ok, %Issue{} = updated} = Issues.remove_assignees(issue, ["bob"])
      assert updated.assignees == [%{"login" => "alice"}]
    end

    test "remove_assignees/2 tolerates an issue with no assignees" do
      issue = issue_fixture()
      assert {:ok, %Issue{assignees: []}} = Issues.remove_assignees(issue, ["alice"])
    end
  end

  describe "set_milestone/2" do
    test "attaches the milestone by number" do
      milestone = milestone_fixture(title: "v1", state: "open")
      issue = issue_fixture()

      assert {:ok, %Issue{} = updated} = Issues.set_milestone(issue, milestone.number)
      assert updated.milestone["number"] == milestone.number
      assert updated.milestone["title"] == "v1"
    end

    test "clears the milestone with nil" do
      milestone = milestone_fixture(title: "v1")
      issue = issue_fixture()
      {:ok, issue} = Issues.set_milestone(issue, milestone.number)

      assert {:ok, %Issue{milestone: nil}} = Issues.set_milestone(issue, nil)
    end

    test "raises for an unknown milestone number" do
      issue = issue_fixture()
      assert_raise Ecto.NoResultsError, fn -> Issues.set_milestone(issue, 404) end
    end
  end

  describe "comments" do
    test "create_comment/1 stores the comment and bumps the issue counter" do
      issue = issue_fixture()

      assert {:ok, %Comment{} = comment} =
               Issues.create_comment(%{body: "hello", issue_id: issue.id})

      assert comment.body == "hello"
      assert comment.issue_id == issue.id
      refute is_nil(comment.created_at)
      refute is_nil(comment.updated_at)

      assert Issues.get_issue!(repository(), issue.id).comments == 1
    end

    test "create_comment/1 keeps explicit timestamps" do
      issue = issue_fixture()
      at = ~U[2026-01-01 00:00:00Z]

      assert {:ok, %Comment{} = comment} =
               Issues.create_comment(%{
                 "body" => "hello",
                 "issue_id" => issue.id,
                 "created_at" => at,
                 "updated_at" => at
               })

      assert comment.created_at == at
      assert comment.updated_at == at
    end

    test "create_comment/1 stores the author payload" do
      issue = issue_fixture()

      assert {:ok, %Comment{} = comment} =
               Issues.create_comment(%{
                 body: "hello",
                 issue_id: issue.id,
                 user: %{"login" => "alice"}
               })

      assert comment.user == %{"login" => "alice"}
    end

    test "create_comment/1 rejects a blank body and leaves the counter alone" do
      issue = issue_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Issues.create_comment(%{body: nil, issue_id: issue.id})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
      assert Issues.get_issue!(repository(), issue.id).comments == 0
    end

    test "create_comment/1 requires an issue_id" do
      assert {:error, %Ecto.Changeset{} = changeset} = Issues.create_comment(%{body: "orphan"})
      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_comment/0 refuses an empty comment" do
      assert {:error, %Ecto.Changeset{} = changeset} = Issues.create_comment(%{})
      assert %{body: ["can't be blank"], issue_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "get_comment!/1 returns the comment" do
      issue = issue_fixture()
      {:ok, comment} = Issues.create_comment(%{body: "hello", issue_id: issue.id})

      assert Issues.get_comment!(repository(), comment.id) == comment
    end

    test "get_comment!/1 raises for an unknown id" do
      issue = issue_fixture()
      {:ok, comment} = Issues.create_comment(%{body: "hello", issue_id: issue.id})

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_comment!(repository(), comment.id + 1)
      end
    end

    test "list_comments/1 is scoped to one issue and ordered by creation time" do
      issue = issue_fixture(title: "mine")
      other = issue_fixture(title: "theirs")

      {:ok, second} =
        Issues.create_comment(%{
          body: "second",
          issue_id: issue.id,
          created_at: ~U[2026-01-02 00:00:00Z],
          updated_at: ~U[2026-01-02 00:00:00Z]
        })

      {:ok, first} =
        Issues.create_comment(%{
          body: "first",
          issue_id: issue.id,
          created_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _elsewhere} = Issues.create_comment(%{body: "elsewhere", issue_id: other.id})

      assert Issues.list_comments(issue) |> Enum.map(& &1.id) == [first.id, second.id]
    end

    test "list_comments/1 returns an empty list for an issue with no comments" do
      issue = issue_fixture()
      assert Issues.list_comments(issue) == []
    end

    test "update_comment/2 edits the body and bumps updated_at" do
      issue = issue_fixture()

      {:ok, comment} =
        Issues.create_comment(%{
          body: "before",
          issue_id: issue.id,
          created_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, %Comment{} = updated} = Issues.update_comment(comment, %{body: "after"})

      assert updated.body == "after"
      assert updated.created_at == comment.created_at
      assert DateTime.after?(updated.updated_at, comment.updated_at)
    end

    test "update_comment/2 rejects a blank body" do
      issue = issue_fixture()
      {:ok, comment} = Issues.create_comment(%{body: "before", issue_id: issue.id})

      assert {:error, %Ecto.Changeset{}} = Issues.update_comment(comment, %{body: nil})
      assert Issues.get_comment!(repository(), comment.id).body == "before"
    end

    test "delete_comment/1 removes it and decrements the issue counter" do
      issue = issue_fixture()
      {:ok, comment} = Issues.create_comment(%{body: "hello", issue_id: issue.id})
      assert Issues.get_issue!(repository(), issue.id).comments == 1

      assert {:ok, :ok} = Issues.delete_comment(comment)

      assert_raise Ecto.NoResultsError, fn -> Issues.get_comment!(repository(), comment.id) end
      assert Issues.get_issue!(repository(), issue.id).comments == 0
    end

    test "the counter tracks several comments" do
      issue = issue_fixture()
      {:ok, a} = Issues.create_comment(%{body: "a", issue_id: issue.id})
      {:ok, _b} = Issues.create_comment(%{body: "b", issue_id: issue.id})
      assert Issues.get_issue!(repository(), issue.id).comments == 2

      {:ok, :ok} = Issues.delete_comment(a)
      assert Issues.get_issue!(repository(), issue.id).comments == 1
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})

  defp issue_fixture(attrs \\ %{}) do
    OpenAgents.IssuesFixtures.issue_fixture(repository(), attrs)
  end

  defp label_fixture(attrs) do
    OpenAgents.LabelsFixtures.label_fixture(repository(), attrs)
  end

  defp milestone_fixture(attrs) do
    OpenAgents.MilestonesFixtures.milestone_fixture(repository(), attrs)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
