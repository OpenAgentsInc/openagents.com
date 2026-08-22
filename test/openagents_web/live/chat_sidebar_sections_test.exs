defmodule OpenAgentsWeb.ChatSidebarSectionsTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias OpenAgents.{Conversations, Work}

  test "the work section is hidden while there is no background work", %{conn: conn} do
    conn = log_in_github_user(conn, "sidebar-sections-empty-browser")
    {:ok, view, _html} = live(conn, ~p"/sarah")

    refute has_element?(view, "#sidebar-work")

    # The calls section was removed; nothing renders it.
    refute has_element?(view, "#sidebar-calls")
  end

  test "a seeded job renders a two-line status row targeting its durable report", %{conn: conn} do
    user = github_user("sidebar-sections-seeded-browser")
    conn = log_in_github_user(conn, "sidebar-sections-seeded-browser")

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Collect the release notes"
      })

    {:ok, running} = Work.mark_job_running(job, %{})
    {:ok, finished} = Work.finish_job(running.id, "completed")

    {:ok, view, _html} = live(conn, ~p"/sarah")

    assert has_element?(view, ~s(#sidebar-job-#{job.id}[data-status="completed"]))
    assert has_element?(view, "#sidebar-job-#{job.id} .sidebar-row__title", "Collect the release")
    assert has_element?(view, "#sidebar-job-#{job.id} .sidebar-row__meta", "Completed")

    assert has_element?(
             view,
             ~s(#sidebar-job-#{job.id} .status-indicator[data-state="succeeded"])
           )

    assert has_element?(
             view,
             ~s(#sidebar-job-#{job.id} a.sidebar-row__hit[href="#messages-#{finished.report_message_id}"])
           )
  end

  test "work has two placements: the navigation sidebar and the wide-screen rail",
       %{conn: conn} do
    user = github_user("sidebar-sections-rail-browser")
    conn = log_in_github_user(conn, "sidebar-sections-rail-browser")

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Rebuild the staging index"
      })

    {:ok, view, _html} = live(conn, ~p"/sarah")

    # Both placements are in the document and the stylesheet shows exactly one:
    # the sidebar section below 1280px, the rail above it.
    assert has_element?(view, "#sidebar-work.chat-sidebar-work #sidebar-job-#{job.id}")
    assert has_element?(view, "#chat-rail #chat-rail-body #rail-work #rail-job-#{job.id}")

    # The rail is the conversation column's sibling, not something stacked
    # under the composer, so the transcript keeps the height it is given.
    assert has_element?(view, ".chat-shell > .app-main")
    assert has_element?(view, ".chat-shell > #chat-rail")
  end

  test "job lifecycle broadcasts refresh the work section without polling", %{conn: conn} do
    user = github_user("sidebar-sections-job-broadcast-browser")
    conn = log_in_github_user(conn, "sidebar-sections-job-broadcast-browser")

    {:ok, view, _html} = live(conn, ~p"/sarah")
    refute has_element?(view, "#sidebar-work")

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "Summarize the meeting notes"
      })

    assert eventually(fn ->
             has_element?(
               view,
               ~s(#sidebar-job-#{job.id} .status-indicator[data-state="running"])
             )
           end)

    # No durable report yet: honest non-link row.
    refute has_element?(view, "#sidebar-job-#{job.id} .sidebar-row__hit")

    {:ok, running} = Work.mark_job_running(job, %{})
    {:ok, finished} = Work.finish_job(running.id, "completed")

    assert eventually(fn ->
             has_element?(
               view,
               ~s(#sidebar-job-#{job.id} a.sidebar-row__hit[href="#messages-#{finished.report_message_id}"])
             )
           end)

    assert has_element?(view, "#sidebar-job-#{job.id} .sidebar-row__meta", "Completed")
  end

  defp eventually(assertion, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(assertion, deadline)
  end

  defp do_eventually(assertion, deadline) do
    if assertion.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
          _message -> :ok
        after
          10 -> :ok
        end

        do_eventually(assertion, deadline)
      end
    end
  end
end
