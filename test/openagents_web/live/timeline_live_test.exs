defmodule OpenAgentsWeb.TimelineLiveTest do
  @moduledoc """
  `/timeline` renders the current account's unified activity, newest first,
  and never shows another account's records.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.{Conversations, Repo, Threads}

  test "renders newest-first entries from more than one modality and excludes other accounts", %{
    conn: conn
  } do
    me = github_user("timeline-live-me")
    other = github_user("timeline-live-other")

    # An older coder entry.
    {:ok, my_thread} = Threads.open(me, "My timeline thread")
    [opened_event] = Threads.list_events(my_thread)

    old_time = DateTime.from_naive!(~N[2026-01-01 10:00:00.000000], "Etc/UTC")

    opened_event
    |> Ecto.Changeset.change(emitted_at: old_time)
    |> Repo.update!()

    # A newer chat entry.
    {:ok, conversation} = Conversations.ensure_conversation(me)
    {:ok, %{turn: turn}} = Conversations.create_turn(conversation, "Chat message for timeline")

    # Another account's entry must not appear.
    {:ok, other_thread} = Threads.open(other, "Other private thread")
    [other_event] = Threads.list_events(other_thread)

    conn = log_in_github_user(conn, "timeline-live-me")
    assert {:ok, view, _html} = live(conn, ~p"/timeline")

    html = render(view)

    assert html =~ "Chat message for timeline"
    assert html =~ "Thread opened"
    refute html =~ ~s(id="timeline-entry-#{other_event.id}")

    assert has_element?(view, "#timeline-entry-#{turn.id}")
    assert has_element?(view, "#timeline-entry-#{opened_event.id}")

    # Newest-first: the chat row appears before the older thread row.
    {chat_pos, _} = :binary.match(html, ~s(id="timeline-entry-#{turn.id}"))
    {coder_pos, _} = :binary.match(html, ~s(id="timeline-entry-#{opened_event.id}"))
    assert chat_pos < coder_pos
  end

  test "anonymous browser is redirected without revealing the timeline", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/timeline")
  end
end
