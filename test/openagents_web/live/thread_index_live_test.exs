defmodule OpenAgentsWeb.ThreadIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenAgents.Threads

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "owner sees own threads and nobody else's", %{conn: conn} do
    owner = github_user("thread-index-owner")
    other = github_user("thread-index-other")

    {:ok, mine} = Threads.open(owner, "List my work")
    {:ok, theirs} = Threads.open(other, "Somebody else's work")

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert has_element?(view, "#threads-table")
    assert has_element?(view, "#thread-link-#{mine.id}")
    refute has_element?(view, "#thread-link-#{theirs.id}")
  end

  test "a row carries status and event count without reading the transcript", %{conn: conn} do
    owner = github_user("thread-index-shell")
    {:ok, thread} = Threads.open(owner, "Shell projection")
    {:ok, _updated} = Threads.record_event(thread, "turn.user", %{"text" => "hi"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert view |> element("#threads-#{thread.id}") |> render() =~ "open"
    assert view |> element("#threads-#{thread.id}") |> render() =~ ">2<"
  end

  test "a row names its repository when the thread records one", %{conn: conn} do
    owner = github_user("thread-index-repository")

    {:ok, named} =
      Threads.open(owner, "Coder session", repository: "OpenAgentsInc/openagents.com")

    {:ok, bare} = Threads.open(owner, "No repository")

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert view |> element("#thread-repository-#{named.id}") |> render() =~
             "OpenAgentsInc/openagents.com"

    refute has_element?(view, "#thread-repository-#{bare.id}")
  end

  test "an account with no threads sees the empty state", %{conn: conn} do
    owner = github_user("thread-index-empty")

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert has_element?(view, "#threads-empty")
    refute has_element?(view, "#threads-table")
  end

  test "anonymous browser is redirected", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/threads")
  end

  test "a newly opened thread dynamically updates the live table", %{conn: conn} do
    owner = github_user("thread-index-live-owner")
    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert has_element?(view, "#threads-empty")
    refute has_element?(view, "#threads-table")

    {:ok, thread} = Threads.open(owner, "Live stream test thread")

    assert has_element?(view, "#threads-table")
    assert has_element?(view, "#thread-link-#{thread.id}")
    refute has_element?(view, "#threads-empty")
  end

  test "an updated thread updates its row live", %{conn: conn} do
    owner = github_user("thread-index-update-owner")
    {:ok, thread} = Threads.open(owner, "Initial thread status")

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads")

    assert view |> element("#threads-#{thread.id}") |> render() =~ "open"

    {:ok, _finished} = Threads.finish(thread, %{status: "succeeded", report: "All done"})

    assert view |> element("#threads-#{thread.id}") |> render() =~ "succeeded"
  end
end
