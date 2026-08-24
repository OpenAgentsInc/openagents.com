defmodule OpenAgentsWeb.ThreadShowUpdatesTest do
  # async: false — the test broadcasts through the shared PubSub into a
  # LiveView process, following the other *_updates_test files.
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Threads

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "a recorded event streams into the open transcript in order", %{conn: conn} do
    owner = github_user("thread-show-live")
    {:ok, thread} = Threads.open(owner, "Watch it live")

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

    {:ok, thread} = Threads.record_event(thread, "turn.user", %{"text" => "streamed in"})
    {:ok, thread} = Threads.record_event(thread, "turn.assistant", %{"text" => "and answered"})

    # Local PubSub dispatch sends before returning, so the view's mailbox
    # holds both events; get_state synchronizes past them.
    _ = :sys.get_state(view.pid)

    [user_event, assistant_event] =
      thread
      |> Threads.list_events()
      |> Enum.filter(&(&1.event_type in ["turn.user", "turn.assistant"]))

    assert view |> element("#events-#{user_event.id}") |> render() =~ "streamed in"
    assert view |> element("#events-#{assistant_event.id}") |> render() =~ "and answered"

    # thread.opened + the two appends.
    assert view |> element("#thread-event-count") |> render() =~ ">3<"

    # Order: the ids are monotonic and the DOM keeps append order.
    html = render(view)

    assert :binary.match(html, "events-#{user_event.id}") <
             :binary.match(html, "events-#{assistant_event.id}")
  end

  test "an event already in the snapshot is not doubled by its broadcast", %{conn: conn} do
    owner = github_user("thread-show-dedup")
    {:ok, thread} = Threads.open(owner, "Dedup by id")
    {:ok, thread} = Threads.record_event(thread, "turn.user", %{"text" => "snapshotted"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

    [event] = Enum.filter(Threads.list_events(thread), &(&1.event_type == "turn.user"))

    # Replay the broadcast the view may have buffered during mount.
    send(view.pid, {:thread_event, event})
    _ = :sys.get_state(view.pid)

    assert view |> element("#thread-event-count") |> render() =~ ">2<"
    assert has_element?(view, "#events-#{event.id}")
  end
end
