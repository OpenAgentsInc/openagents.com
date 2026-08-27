defmodule OpenAgentsWeb.ThreadShowLiveTest do
  # `async: false` because the unpriced-lane test below rewrites
  # `:model_catalog`, which every process in the node reads.
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Inference.Models
  alias OpenAgents.Threads
  alias OpenAgents.UnpricedLane

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp event_id(thread, event_type) do
    thread
    |> Threads.list_events()
    |> Enum.find(&(&1.event_type == event_type))
    |> Map.fetch!(:id)
  end

  test "renders each event kind of the vocabulary typed", %{conn: conn} do
    owner = github_user("thread-show-kinds")
    {:ok, thread} = Threads.open(owner, "Render the vocabulary")

    {:ok, thread} =
      Threads.record_event(thread, "turn.user", %{"text" => "Fix the bug", "steered" => true})

    {:ok, thread} =
      Threads.record_event(thread, "turn.reasoning", %{"text" => "The bug is in the parser."})

    {:ok, thread} =
      Threads.record_event(thread, "tool.ran", %{
        "tool" => "read_file",
        "status" => "ok",
        "arguments" => %{"path" => "lib/parser.ex"},
        "result" => "defmodule Parser do"
      })

    {:ok, thread} =
      Threads.record_event(thread, "turn.assistant", %{
        "text" => "Fixed. The parser **now** handles it.",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 25, "total_tokens" => 125}
      })

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

    user_id = event_id(thread, "turn.user")

    assert view |> element("#events-#{user_id}[data-kind='turn.user']") |> render() =~
             "Fix the bug"

    assert view |> element("#events-#{user_id}") |> render() =~ "steered"

    reasoning_id = event_id(thread, "turn.reasoning")

    assert view |> element("#events-#{reasoning_id}[data-kind='turn.reasoning']") |> render() =~
             "The bug is in the parser."

    assert has_element?(view, "#events-#{reasoning_id} details")

    tool_id = event_id(thread, "tool.ran")
    tool_row = view |> element("#events-#{tool_id}[data-kind='tool.ran']") |> render()
    assert tool_row =~ "read_file"
    assert tool_row =~ "lib/parser.ex"
    assert tool_row =~ "defmodule Parser do"
    assert tool_row =~ "ok"

    assistant_id = event_id(thread, "turn.assistant")

    assistant_row =
      view |> element("#events-#{assistant_id}[data-kind='turn.assistant']") |> render()

    assert assistant_row =~ "<strong>now</strong>"
    assert assistant_row =~ "125 total"
  end

  test "an unknown event type renders as a neutral raw row", %{conn: conn} do
    owner = github_user("thread-show-unknown")
    {:ok, thread} = Threads.open(owner, "Survive the unknown")

    {:ok, thread} =
      Threads.record_event(thread, "plugin.custom", %{"whatever" => ["shape", 1, true]})

    # A typed event whose payload misses its text degrades the same way.
    {:ok, thread} = Threads.record_event(thread, "turn.user", %{"no_text" => true})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

    unknown_id = event_id(thread, "plugin.custom")

    assert view |> element("#events-#{unknown_id}[data-kind='plugin.custom']") |> render() =~
             "plugin.custom"

    textless_id = event_id(thread, "turn.user")
    assert view |> element("#events-#{textless_id}") |> render() =~ "no_text"
  end

  test "another account's thread id is a plain 404", %{conn: conn} do
    owner = github_user("thread-show-owner")
    intruder = github_user("thread-show-intruder")
    {:ok, thread} = Threads.open(owner, "Private work")

    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(signed_in(conn, intruder), ~p"/threads/#{thread.id}")
    end
  end

  test "an unknown id is the same 404", %{conn: conn} do
    viewer = github_user("thread-show-unknown-id")

    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(signed_in(conn, viewer), ~p"/threads/#{Ecto.UUID.generate()}")
    end

    assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
      live(signed_in(conn, viewer), ~p"/threads/not-a-uuid")
    end
  end

  # METER-001. This cell used to read "$0.00 / $100.00" for a session on the
  # lane the coder actually runs on, which is the most confident wrong number
  # the product could show.
  describe "the budget card's cost cell" do
    test "an unpriced lane shows the word, never a dollar figure", %{conn: conn} do
      owner = github_user("thread-show-unpriced")

      # `gpt-5.6-luna` was the shipped unpriced lane until it was withdrawn.
      previous = UnpricedLane.admit!()
      on_exit(fn -> UnpricedLane.restore(previous) end)
      unpriced = UnpricedLane.id()

      {:ok, thread} = Threads.open(owner, "Run the unpriced lane", model: unpriced)
      {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)

      {:ok, _metered} =
        OpenAgents.Inference.record_usage(grant, %{"input_tokens" => 900, "output_tokens" => 80})

      {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

      cost = view |> element("#thread-budget-cost") |> render()

      assert cost =~ "Unpriced"
      refute cost =~ "$0.00"
      assert view |> element("#thread-budget-cost-note") |> render() =~ "unknown rather than zero"
    end

    test "a declared priced lane shows the billable figure", %{conn: conn} do
      owner = github_user("thread-show-priced")

      {:ok, thread} = Threads.open(owner, "Run a lane with rates")
      {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
      {:ok, _metered} = OpenAgents.Inference.record_usage(grant, %{"input_tokens" => 1_000_000})

      {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

      # A million input tokens costs exactly the default lane's per-million
      # rate, rendered in dollars.
      dollars = Models.default().pricing.input_per_million_tokens / 1_000_000

      assert view |> element("#thread-budget-cost") |> render() =~
               "$#{:erlang.float_to_binary(dollars, decimals: 2)}"

      assert has_element?(view, ~s(#thread-budget-cost[data-basis="declared"]))
      refute has_element?(view, "#thread-budget-cost-note")
    end

    test "an unbounded ceiling reads as unbounded rather than blank", %{conn: conn} do
      owner = github_user("thread-show-unbounded")

      {:ok, thread} = Threads.open(owner, "No ceilings but the account's")
      {:ok, _fenced, _grant, _token} = Threads.mint_grant(thread)

      {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

      assert view |> element("#thread-budget") |> render() =~ "\u221e"
    end
  end
end
