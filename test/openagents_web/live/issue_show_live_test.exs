defmodule OpenAgentsWeb.IssueShowLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.AccountsFixtures
  import OpenAgents.LabelsFixtures
  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Accounts
  alias OpenAgents.Issues
  alias OpenAgents.Issues.ClosingReferences
  alias OpenAgents.Repositories

  setup %{conn: conn} do
    {:ok, conn: log_in_repository_user(conn, "issue-show", repository())}
  end

  defp issue!(attrs) do
    {:ok, issue} = Issues.create_issue(repository(), attrs)
    issue
  end

  defp path(issue), do: ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}"

  test "mounts and renders the title, number, state, and body", %{conn: conn} do
    issue =
      issue!(%{
        "title" => "Streaming stalls",
        "body" => "It hangs",
        "user" => %{"login" => "ada"}
      })

    {:ok, view, html} = live(conn, path(issue))

    assert html =~ "Streaming stalls"
    assert html =~ "##{issue.number}"
    assert html =~ "It hangs"
    assert html =~ "ada"
    assert has_element?(view, ~s{button[phx-click="close"]}, "Close issue")
    refute has_element?(view, ~s{button[phx-click="reopen"]})
  end

  test "an issue with no body says so rather than rendering blank", %{conn: conn} do
    issue = issue!(%{"title" => "Bare"})

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "No description provided."
    assert html =~ "anonymous"
  end

  # This used to assert that an empty section was hidden, which was right while
  # the rail was read-only. The rail is editable now, and a field you cannot
  # see is a field you cannot set: hiding "Labels" until an issue has one means
  # an issue can never get its first label. So the group is always present and
  # states its own emptiness instead.
  test "an empty property group says so rather than disappearing", %{conn: conn} do
    grace = repository_user_fixture("grace-show")
    {:ok, _membership} = Repositories.add_member(repository(), grace, "contributor")
    bare = issue!(%{"title" => "Bare"})
    {:ok, view, html} = live(conn, path(bare))

    assert html =~ "Labels"
    assert html =~ "Assignees"
    assert html =~ "Milestone"
    assert html =~ "None yet"
    assert html =~ "No one assigned"
    assert html =~ "No milestone"

    # And each one offers the control that fills it.
    for id <- ~w(issue-label-menu issue-assignee-menu issue-milestone-menu issue-state-menu) do
      assert has_element?(view, ~s{button[popovertarget="#{id}"]}),
             "the #{id} property is stated but cannot be changed"
    end

    label_fixture(repository(), %{name: "bug", color: "d73a4a"})
    milestone = milestone_fixture(repository(), %{title: "v1.0", due_on: nil})

    rich = issue!(%{"title" => "Rich", "labels" => ["bug"], "assignees" => ["grace-show"]})
    {:ok, rich} = Issues.set_milestone(rich, milestone.number)

    {:ok, view, html} = live(conn, path(rich))

    assert html =~ "bug"
    refute html =~ "None yet"
    assert has_element?(view, ~s{[title="grace-show"]})
    assert has_element?(view, ~s{a[href="/OpenAgentsInc/openagents.com/milestones"]}, "v1.0")
  end

  test "the rail changes state, labels, assignees, and the milestone", %{conn: conn} do
    hopper = repository_user_fixture("hopper-show")
    {:ok, _membership} = Repositories.add_member(repository(), hopper, "contributor")
    label_fixture(repository(), %{name: "bug", color: "d73a4a"})
    milestone = milestone_fixture(repository(), %{title: "v2.0", due_on: nil})
    issue = issue!(%{"title" => "Editable"})

    {:ok, view, _html} = live(conn, path(issue))

    view
    |> element(~s{#issue-label-menu button}, "bug")
    |> render_click()

    assert Issues.get_issue!(repository(), issue.id).labels |> Enum.map(& &1["name"]) == ["bug"]

    view
    |> element(~s{#issue-assignee-menu button}, "hopper-show")
    |> render_click()

    assert Issues.get_issue!(repository(), issue.id).assignees |> Enum.map(& &1["login"]) == [
             "hopper-show"
           ]

    view
    |> element(~s{#issue-milestone-menu button}, "v2.0")
    |> render_click()

    assert Issues.get_issue!(repository(), issue.id).milestone["number"] == milestone.number

    # The rail can pick a close reason the header's two buttons cannot.
    view
    |> element(~s{#issue-state-menu button}, "Closed as not planned")
    |> render_click()

    closed = Issues.get_issue!(repository(), issue.id)
    assert closed.state == "closed"
    assert closed.state_reason == "not_planned"

    # Clicking the same option again unsets it, because a set is a toggle.
    view
    |> element(~s{#issue-label-menu button}, "bug")
    |> render_click()

    assert Issues.get_issue!(repository(), issue.id).labels == []
  end

  test "a member who loses write access cannot triage through an open page", %{conn: conn} do
    user = Accounts.get_user(Plug.Conn.get_session(conn, "user_id"))
    issue = issue!(%{"title" => "Authority changed"})
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")

    {:ok, view, _html} = live(conn, path(issue))
    {:ok, _} = Repositories.add_member(repository, user, "viewer")

    html = render_click(view, "toggle_label", %{"name" => "bug"})

    assert html =~ "Only repository members can change issue labels"
    assert Issues.get_issue!(repository(), issue.id).labels == []
  end

  test "the history is one feed of comments and state changes", %{conn: conn} do
    issue = issue!(%{"title" => "Threaded"})
    {:ok, view, html} = live(conn, path(issue))

    assert html =~ "opened this issue"

    view
    |> form("#comment-form", comment: %{body: "First"})
    |> render_submit()

    html = view |> element(~s{button[phx-click="close"]}) |> render_click()

    assert html =~ "First"
    assert html =~ "closed this as completed"

    # The close has no actor. This schema records when an issue was closed but
    # not by whom, and a sentence with an invented subject would be worse than
    # one without a subject at all.
    refute html =~ "issue-show closed this"
  end

  test "a comment from the issue's own author is marked as such", %{conn: conn} do
    # GitHub derives the Author badge by comparing the commenter to the issue's
    # author rather than storing it, so this asserts the comparison, not a field.
    issue = issue!(%{"title" => "Self-answered", "user" => %{"login" => "ada"}})

    {:ok, _} =
      Issues.create_comment(%{
        "issue_id" => issue.id,
        "body" => "Answering my own question",
        "user" => %{"login" => "ada"}
      })

    {:ok, _} =
      Issues.create_comment(%{
        "issue_id" => issue.id,
        "body" => "So am I",
        "user" => %{"login" => "grace"}
      })

    {:ok, view, _html} = live(conn, path(issue))

    assert has_element?(view, ".timeline-comment__badge", "Author")

    assert length(
             LazyHTML.query(document(view), ".timeline-comment__badge")
             |> LazyHTML.to_tree()
           ) ==
             1
  end

  defp document(view), do: view |> render() |> LazyHTML.from_fragment()

  test "a missing issue number raises rather than rendering an empty page", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/OpenAgentsInc/openagents.com/issues/9999")
    end
  end

  test "closing then reopening an issue swaps the action buttons", %{conn: conn} do
    issue = issue!(%{"title" => "Toggle me"})
    {:ok, view, _html} = live(conn, path(issue))

    html = view |> element(~s{button[phx-click="close"]}) |> render_click()

    assert html =~ "Issue closed"
    assert has_element?(view, ~s{button[phx-click="reopen"]}, "Reopen issue")
    refute has_element?(view, ~s{button[phx-click="close"]})

    closed = Issues.get_issue!(repository(), issue.id)
    assert closed.state == "closed"
    assert closed.state_reason == "completed"
    assert closed.closed_at

    html = view |> element(~s{button[phx-click="reopen"]}) |> render_click()

    assert html =~ "Issue reopened"
    assert has_element?(view, ~s{button[phx-click="close"]}, "Close issue")

    reopened = Issues.get_issue!(repository(), issue.id)
    assert reopened.state == "open"
    assert reopened.closed_at == nil
  end

  test "the edit toggle swaps the header for the edit form and back", %{conn: conn} do
    issue = issue!(%{"title" => "Editable", "body" => "Before"})
    {:ok, view, _html} = live(conn, path(issue))

    refute has_element?(view, "#issue-edit-form")

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()
    assert has_element?(view, "#issue-edit-form")
    refute has_element?(view, ~s{button[phx-click="close"]})

    view |> element(~s{#issue-edit-form button[phx-click="toggle_edit"]}) |> render_click()
    refute has_element?(view, "#issue-edit-form")
    assert has_element?(view, ~s{button[phx-click="close"]})
  end

  test "saving the edit form updates the issue and leaves edit mode", %{conn: conn} do
    issue = issue!(%{"title" => "Editable", "body" => "Before"})
    {:ok, view, _html} = live(conn, path(issue))

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()

    html =
      view
      |> form("#issue-edit-form", issue: %{title: "Edited", body: "After"})
      |> render_submit()

    assert html =~ "Issue updated"
    assert html =~ "Edited"
    assert html =~ "After"
    refute has_element?(view, "#issue-edit-form")

    updated = Issues.get_issue!(repository(), issue.id)
    assert updated.title == "Edited"
    assert updated.body == "After"
  end

  test "clearing the title in the edit form keeps the form and shows the error", %{conn: conn} do
    issue = issue!(%{"title" => "Editable"})
    {:ok, view, _html} = live(conn, path(issue))

    view |> element(~s{button[phx-click="toggle_edit"]}) |> render_click()

    html =
      view
      |> form("#issue-edit-form", issue: %{title: "", body: "still here"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#issue-edit-form")
    assert Issues.get_issue!(repository(), issue.id).title == "Editable"
  end

  test "adding a comment appends it to the thread and bumps the count", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})
    {:ok, view, html} = live(conn, path(issue))

    assert has_element?(view, "#comment-form")
    refute html =~ "Looks good to me"

    html =
      view
      |> form("#comment-form", comment: %{body: "Looks good to me"})
      |> render_submit()

    assert html =~ "Comment added"
    assert html =~ "Looks good to me"
    assert html =~ "anonymous"

    assert [comment] = Issues.list_comments(issue)
    assert comment.body == "Looks good to me"
    assert Issues.get_issue!(repository(), issue.id).comments == 1
  end

  test "an empty comment body is rejected and nothing is stored", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})
    {:ok, view, _html} = live(conn, path(issue))

    html =
      view
      |> form("#comment-form", comment: %{body: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Issues.list_comments(issue) == []
    assert Issues.get_issue!(repository(), issue.id).comments == 0
  end

  test "existing comments render with their author on mount", %{conn: conn} do
    issue = issue!(%{"title" => "Discuss"})

    {:ok, _} =
      Issues.create_comment(%{
        issue_id: issue.id,
        body: "Earlier note",
        user: %{"login" => "ada"}
      })

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "Earlier note"
    assert html =~ "ada"
  end

  # Reading is public on a public repository; the page shows the conversation
  # and an invitation to sign in, and no control that writes.
  test "an anonymous visitor reads an issue page without write controls" do
    issue = issue!(%{"title" => "Public reading"})

    {:ok, view, html} = live(build_conn(), path(issue))

    assert html =~ "Public reading"
    assert has_element?(view, "#sign-in-to-comment")
    refute has_element?(view, "#comment-form")
    refute has_element?(view, ~s{button[phx-click="close"]})
    refute has_element?(view, ~s{button[phx-click="toggle_edit"]})
  end

  test "the timeline shows every agent attempt, started and finished", %{conn: conn} do
    issue = issue!(%{"title" => "Worked by an agent"})
    sha = String.duplicate("ef", 20)

    record_attempt(issue, "agent/one", -600, %{state: "failed", failure_reason: "timeout"})
    record_attempt(issue, "agent/two", -60, %{state: "completed", terminal_commit: sha})

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "started work on a computer, on branch agent/one"
    assert html =~ "stopped this work: timeout"
    assert html =~ "started work on a computer, on branch agent/two"
    assert html =~ "finished this work at #{String.slice(sha, 0, 7)}"
  end

  test "an issue nobody has worked renders its timeline unchanged", %{conn: conn} do
    issue = issue!(%{"title" => "Never worked"})

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "opened this issue"
    refute html =~ "started work on"
  end

  # The attempt record is `forge_assignments`. Writing one directly keeps this
  # test about what the page renders rather than about the admission path.
  defp record_attempt(issue, branch, offset_seconds, overrides) do
    user = repository_user_fixture("attempt-#{System.unique_integer([:positive])}")

    {:ok, %{code: code}} =
      OpenAgents.Machines.start_pairing(%{
        "name" => branch,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = OpenAgents.Machines.approve_pairing(user, code)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    admitted_at = DateTime.add(now, offset_seconds, :second)
    state = Map.get(overrides, :state, "running")

    %OpenAgents.Forge.Assignment{}
    |> OpenAgents.Forge.Assignment.changeset(
      Map.merge(
        %{
          target_kind: "computer",
          machine_id: machine.id,
          repository_id: repository().id,
          issue_id: issue.id,
          requesting_principal: %{"type" => "user", "id" => user.id},
          branch: branch,
          state: state,
          admitted_at: admitted_at,
          started_at: admitted_at,
          finished_at:
            if(state in OpenAgents.Forge.Assignment.terminal_states(), do: admitted_at),
          deadline_at: DateTime.add(admitted_at, 3600, :second)
        },
        overrides
      )
    )
    |> OpenAgents.Repo.insert!()
  end

  # #130: a close that arrived from a commit names the commit, and the entry
  # links back to it. The derived close, which can name neither the actor nor
  # the commit, steps aside where a commit did the closing.
  test "the timeline links back to the commit that closed the issue", %{conn: conn} do
    issue = issue!(%{"title" => "Closed by a push"})
    sha = "9606cbc0e0f1a2b3c4d5e6f708192a3b4c5d6e7f"
    actor = github_user("issue-show")

    assert [_reference] =
             ClosingReferences.apply_commit(
               repository(),
               actor,
               sha,
               "Ship it\n\nCloses ##{issue.number}"
             )

    {:ok, view, html} = live(conn, path(issue))

    assert html =~ "closed this as completed in"
    assert html =~ String.slice(sha, 0, 7)

    assert has_element?(
             view,
             ~s{a[href="/OpenAgentsInc/openagents.com/commit/#{sha}"]}
           )
  end

  # #12: an edit nobody made by hand is still an edit somebody can see, and
  # the history says the system made it rather than naming a person who only
  # closed a different issue.
  test "the timeline shows the automatic task-list edit as a system entry", %{conn: conn} do
    child = issue!(%{"title" => "Read the legacy schema"})

    parent =
      issue!(%{
        "title" => "Port the forum",
        "body" => "- [ ] ##{child.number} Read the legacy schema"
      })

    {:ok, _closed} =
      Issues.update_issue(child, %{"state" => "closed", "state_reason" => "completed"}, nil)

    {:ok, _view, html} = live(conn, path(parent))

    assert html =~ "checked the task for ##{child.number}"
    assert html =~ "system"
  end

  # ── #10: the issue page shows the evidence, not only the work ───────────
  #
  # `OUTCOME-001` says an accepted outcome "explains which receipt satisfied
  # each acceptance criterion, so the issue page can show the mapping". The
  # verdict was durable and graded before this, and nowhere on the page. These
  # cover the rail that renders it, the release link, and the ATIF trace line
  # — which says a trajectory exists and never shows one.

  test "an issue with no evidence has no evidence section at all", %{conn: conn} do
    issue = issue!(%{"title" => "Nothing has happened"})

    {:ok, view, _html} = live(conn, path(issue))

    refute has_element?(view, "#issue-evidence")
  end

  test "the work form says what bound the attempt, and why", %{conn: conn} do
    issue = issue!(%{"title" => "Unscoped", "body" => "Make it better."})

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "does not state its"
    assert html =~ "acceptance criteria"
    assert html =~ "no claim against it can be accepted"
  end

  test "a scoped issue says it buys the full hour", %{conn: conn} do
    issue =
      issue!(%{
        "title" => "Scoped",
        "body" => """
        ## Problem

        A bound that comes from the caller is not a bound.

        ## Scope

        One admission point.

        ## Acceptance criteria

        - The wall clock comes from the issue.

        ## Success metrics

        An unscoped issue cannot buy an hour.
        """
      })

    {:ok, _view, html} = live(conn, path(issue))

    assert html =~ "states every section an accepted outcome needs"
  end

  test "the evidence rail says a trajectory exists and never shows one", %{conn: conn} do
    issue = issue!(%{"title" => "Recorded"})
    attempt = record_attempt(issue, "agent/trace", -60, %{state: "completed"})

    owner = OpenAgents.Repo.get!(Accounts.User, attempt.requesting_principal["id"])

    {:ok, _trace, :created} =
      OpenAgents.Traces.store(
        owner,
        %{
          "schema_version" => "ATIF-v1.7",
          "steps" => [%{"step_id" => 1, "message" => "SECRET-TRAJECTORY-CONTENT"}]
        },
        assignment_id: attempt.id,
        visibility: "ledger"
      )

    {:ok, view, html} = live(conn, path(issue))

    assert has_element?(view, "#issue-evidence")
    assert html =~ "An agent trajectory of 1 step was recorded"
    assert html =~ "contents are not published here"

    refute html =~ "SECRET-TRAJECTORY-CONTENT"
  end

  test "a trace the uploader did not consent to publishing stays off the page", %{conn: conn} do
    issue = issue!(%{"title" => "Withheld"})
    attempt = record_attempt(issue, "agent/dark", -60, %{state: "completed"})
    owner = OpenAgents.Repo.get!(Accounts.User, attempt.requesting_principal["id"])

    {:ok, _trace, :created} =
      OpenAgents.Traces.store(
        owner,
        %{"schema_version" => "ATIF-v1.7", "steps" => []},
        assignment_id: attempt.id
      )

    {:ok, view, _html} = live(conn, path(issue))

    refute has_element?(view, "#issue-evidence")
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
