defmodule OpenAgentsWeb.LeaderboardLiveTest do
  @moduledoc """
  The leaderboard is the only Sarah surface a stranger can read, so these tests
  assert both halves of that: it must open without a session, and it must not
  carry anything past the published projection.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Accounts
  alias OpenAgents.Context.Composer
  alias OpenAgents.Conversations
  alias OpenAgents.Leaderboard
  alias OpenAgents.Providers.Request

  setup do
    Leaderboard.refresh()
    :ok
  end

  test "opens for a visitor with no session", %{conn: conn} do
    user = account("public-visitor")

    complete_typed_turn(user, "Public row.", %{
      "input_tokens" => 60,
      "output_tokens" => 40,
      "total_tokens" => 100
    })

    Leaderboard.refresh()

    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ "Leaderboard"
    assert html =~ "@#{user.github_login}"
    assert html =~ "100 tokens"
  end

  test "carries the shared command bar without account controls for a visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ ~s(class="command-bar")
    assert html =~ "OpenAgents"
    refute html =~ ~s(id="account-menu-trigger")
    refute html =~ ~s(id="return-to-conversation")
  end

  test "offers the account menu and a way back to the conversation when logged in", %{conn: conn} do
    conn = log_in_github_user(conn, "leaderboard-header-browser")

    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ ~s(id="account-menu-trigger")
    assert html =~ ~s(id="return-to-conversation")
    assert html =~ "RETURN TO CONVERSATION"
  end

  test "explains itself when no account has spent a token", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ "No tokens yet"
    refute html =~ "leaderboard-rows"
  end

  test "leads with the person's name and keeps the handle as the qualifier", %{conn: conn} do
    user = account("named-leader")

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: user.github_id,
        github_login: user.github_login,
        github_name: "Ada Lovelace",
        github_avatar_url: user.github_avatar_url
      })

    complete_typed_turn(user, "Named row.", %{
      "input_tokens" => 5,
      "output_tokens" => 5,
      "total_tokens" => 10
    })

    Leaderboard.refresh()

    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ "Ada Lovelace"
    assert html =~ "@#{user.github_login}"
  end

  test "publishes no cost, content, or private identifier", %{conn: conn} do
    user = account("bounded-row")
    conversation = conversation_for(user)
    %{turn: turn, receipt: receipt} = begin_typed_turn(conversation, "Private message body.")

    {:ok, _turn} =
      Conversations.complete_turn(turn, "private-response-id", %{
        "input_tokens" => 11,
        "output_tokens" => 9,
        "total_tokens" => 20
      })

    Leaderboard.refresh()

    {:ok, _view, html} = live(conn, ~p"/leaderboard")

    assert html =~ "@#{user.github_login}"
    refute html =~ "Private message body."
    refute html =~ "private-response-id"
    refute html =~ conversation.id
    refute html =~ turn.id
    refute html =~ receipt.id
    refute html =~ "microusd"
    refute html =~ "model-v1"
  end

  test "builds rows from the component library rather than hand-written markup", %{conn: conn} do
    user = account("icon-free")

    complete_typed_turn(user, "Row.", %{"input_tokens" => 1, "output_tokens" => 1})
    Leaderboard.refresh()

    {:ok, view, _html} = live(conn, ~p"/leaderboard")

    rows = view |> element("#leaderboard-rows") |> render()

    # UI-003: glyphs come from the vendored set through the icon component, so a
    # raw <svg> in a board row would be a hand-rolled one.
    refute rows =~ "<svg"
    assert rows =~ ~s(class="card )
    assert rows =~ ~s(class="avatar )
    assert rows =~ ~s(class="badge leaderboard-total")
    assert rows =~ ~s(alt="")
  end

  test "updates live when a turn completes", %{conn: conn} do
    # The one test that exercises the real invalidate -> debounce -> recompute
    # -> fan-out path rather than driving the board by hand.
    previous = Application.get_env(:openagents, :leaderboard_auto_refresh_enabled, true)
    Application.put_env(:openagents, :leaderboard_auto_refresh_enabled, true)

    on_exit(fn ->
      Application.put_env(:openagents, :leaderboard_auto_refresh_enabled, previous)
    end)

    {:ok, view, html} = live(conn, ~p"/leaderboard")
    assert html =~ "No tokens yet"

    user = account("live-updater")

    complete_typed_turn(user, "Arrive on the board.", %{
      "input_tokens" => 70,
      "output_tokens" => 30,
      "total_tokens" => 100
    })

    assert eventually(fn -> render(view) =~ "@#{user.github_login}" end)
  end

  # The board arrives over PubSub after a debounce, so the surface catches up a
  # beat behind the write rather than within one render call.
  defp eventually(check, remaining_ms \\ 2_000) do
    cond do
      check.() -> true
      remaining_ms <= 0 -> flunk("the board never showed the completed turn")
      true -> Process.sleep(25) || eventually(check, remaining_ms - 25)
    end
  end

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 12)

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{suffix}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp conversation_for(user) do
    {:ok, conversation} = Conversations.ensure_conversation(user)
    conversation
  end

  defp complete_typed_turn(user, content, usage) do
    conversation = conversation_for(user)
    %{turn: turn} = begin_typed_turn(conversation, content)
    {:ok, _turn} = Conversations.complete_turn(turn, "response-#{turn.id}", usage)
    :ok
  end

  defp begin_typed_turn(conversation, content) do
    {:ok, records} = Conversations.create_turn(conversation, content)
    context = Composer.compose!()
    messages = Conversations.provider_messages(conversation.id)

    request = %Request{
      model_id: "model-v1",
      instructions: context.instructions,
      input: messages
    }

    {:ok, inference} =
      Conversations.begin_inference(records.turn, context, request, "test.provider", [])

    inference
  end
end
