defmodule OpenAgentsWeb.IssueLiveWorkTest do
  @moduledoc """
  Stage 3 of `#10`: show a running attempt live, and stop narrating it.

  The narration went because it was a surface asserting things nothing could
  contradict. Three Markdown comments restated `forge_assignments` in prose,
  one of them — "claim released" — describing a credential revocation in a
  different table, for two of the three terminal states, while `finish/1`
  revokes for all three. Nothing compared the sentence to the row.

  What replaces it is the row. These tests hold the three properties that makes
  possible: the page moves when the attempt moves, the announcement that moves
  it carries an id and nothing else, and the re-read it triggers goes through
  the viewer's own authorization rather than through whatever the socket last
  believed.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Forge.{Assignment, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  @sha String.duplicate("ab", 20)

  setup %{conn: conn} do
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    member = github_user("issue-live-work-member")
    {:ok, _} = Repositories.add_member(repository, member, "maintainer")

    {:ok, issue} = Issues.create_issue(repository, %{title: "Watch the work"})

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => member.id}),
      member: member,
      repository: repository,
      issue: issue
    }
  end

  defp path(issue), do: ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}"

  describe "the announcement" do
    test "carries the issue id and nothing else", context do
      :ok = Assignments.subscribe_attempts(context.issue.id)
      attempt = attempt(context)

      Assignments.announce(attempt)

      issue_id = context.issue.id
      assert_receive {:attempts_changed, ^issue_id}

      # Nothing else arrives, so nothing carried the branch, the state, the
      # revision, or the row. A subscriber that wants any of those must re-read
      # for them, which is the only place a gate can run.
      refute_receive {:attempts_changed, _issue_id, _anything}
      refute_receive %Assignment{}
    end

    test "reaches only the issue it names", context do
      {:ok, other} = Issues.create_issue(context.repository, %{title: "Elsewhere"})
      :ok = Assignments.subscribe_attempts(other.id)

      Assignments.announce(attempt(context))

      refute_receive {:attempts_changed, _issue_id}
    end
  end

  describe "a running attempt on the page" do
    test "renders its state and how long it has been running", context do
      attempt(context, started_at: DateTime.add(DateTime.utc_now(), -90, :second))

      {:ok, view, _html} = live(context.conn, path(context.issue))

      assert has_element?(view, "#issue-work-live")
      assert render(view) =~ "running"
      assert has_element?(view, "#issue-work-elapsed")
      assert render(view) =~ "1m 3"
    end

    test "lands its terminal event without a reload", context do
      attempt = attempt(context)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      assert has_element?(view, "#issue-work-live")
      refute render(view) =~ "finished this work"

      # The production terminal path, which announces on the topic the page
      # subscribed to at mount. Nothing here touches the view.
      {:ok, _finished} = Assignments.finish(attempt, "completed", @sha)

      html = render(view)
      assert html =~ "finished this work at #{String.slice(@sha, 0, 7)}"
      refute has_element?(view, "#issue-work-live")
    end

    test "an attempt that started and never finished renders as started only", context do
      attempt(context)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      html = render(view)
      assert html =~ "started work on a box"
      refute html =~ "finished this work"
      refute html =~ "stopped this work"
      refute html =~ "cancelled this work"
    end
  end

  describe "cancelling" do
    test "a viewer with write authority ends the attempt through the terminal path",
         context do
      attempt = attempt(context)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      assert has_element?(view, "#issue-work-cancel")
      render_click(view, "cancel_work", %{})

      cancelled = Repo.get!(Assignment, attempt.id)
      assert cancelled.state == "cancelled"
      assert cancelled.failure_reason == "cancelled_by_viewer"
      assert cancelled.finished_at

      refute has_element?(view, "#issue-work-live")
      assert render(view) =~ "cancelled this work"
    end

    test "a reader without write authority is offered no control and refused the event",
         context do
      attempt = attempt(context)

      {:ok, view, _html} = live(build_conn(), path(context.issue))

      refute has_element?(view, "#issue-work-cancel")
      render_click(view, "cancel_work", %{})

      assert Repo.get!(Assignment, attempt.id).state == "running"
    end

    test "is refused for an attempt that already finished", context do
      attempt = attempt(context)
      {:ok, _} = Assignments.finish(attempt, "completed", @sha)

      assert {:error, :assignment_not_live} = Assignments.cancel(attempt.id, context.member)
    end

    test "reads its authority from the attempt's own repository", context do
      attempt = attempt(context)
      stranger = github_user("issue-live-work-stranger")

      assert {:error, :repository_not_writable} = Assignments.cancel(attempt.id, stranger)
      assert {:error, :repository_not_writable} = Assignments.cancel(attempt.id, nil)
      assert Repo.get!(Assignment, attempt.id).state == "running"
    end
  end

  describe "the re-read the announcement triggers" do
    test "runs through this viewer's own authority, not the one it mounted with",
         context do
      attempt(context)

      {:ok, view, _html} = live(context.conn, path(context.issue))

      # A member reads the attempt at `ledger`, so the branch is on the page.
      assert render(view) =~ "agent/watched"

      # Authority changes underneath a mounted socket. Nothing tells the view.
      Repo.delete_all(
        from membership in OpenAgents.Repositories.Membership,
          where:
            membership.repository_id == ^context.repository.id and
              membership.user_id == ^context.member.id
      )

      Assignments.announce(Repo.get!(Assignment, attempt_id(context)))

      # The re-read went through `Repositories.get_visible_repository/2` and
      # `WorkDisclosure.viewer/2` again, so the reader dropped to `pulse` and
      # the branch left the page. A message that carried the attempt would have
      # put it back.
      html = render(view)
      refute html =~ "agent/watched"
      refute has_element?(view, "#issue-work-cancel")
    end
  end

  defp attempt_id(context) do
    Repo.one!(from a in Assignment, where: a.issue_id == ^context.issue.id, select: a.id)
  end

  defp attempt(context, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started_at = Keyword.get(opts, :started_at, now) |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "box",
      conversation_box_id: box(context).id,
      repository_id: context.repository.id,
      issue_id: context.issue.id,
      requesting_principal: %{
        "type" => "user",
        "id" => context.member.id,
        "actor_type" => "user",
        "actor_id" => context.member.id
      },
      branch: "agent/watched",
      state: "running",
      admitted_at: started_at,
      started_at: started_at,
      deadline_at: DateTime.add(now, 3_600, :second)
    })
    |> Repo.insert!()
  end

  defp box(context) do
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(context.member)

    {:ok, box} =
      %OpenAgents.Box.ConversationBox{}
      |> OpenAgents.Box.ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_live_work_#{System.unique_integer([:positive])}",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    box
  end
end
