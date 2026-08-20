defmodule OpenAgents.LeaderboardTest do
  @moduledoc """
  The public board publishes one account's activity to everybody, so the tests
  that matter are the exclusions: who must never appear, and what must never be
  counted twice.
  """

  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Accounts
  alias OpenAgents.Context.Composer
  alias OpenAgents.Conversations
  alias OpenAgents.DataRights
  alias OpenAgents.Leaderboard
  alias OpenAgents.Providers.Request
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.ProviderEvent

  test "totals typed and spoken tokens for one account and ranks them descending" do
    heavy = account("heavy")
    light = account("light")

    complete_typed_turn(heavy, "Heavy typed turn.", %{
      "input_tokens" => 100,
      "output_tokens" => 40,
      "total_tokens" => 140
    })

    record_voice_usage(heavy, "rtc-heavy", %{
      "input_tokens" => 12,
      "output_tokens" => 8,
      "total_tokens" => 20
    })

    complete_typed_turn(light, "Light typed turn.", %{
      "input_tokens" => 3,
      "output_tokens" => 2,
      "total_tokens" => 5
    })

    assert [first, second] = Leaderboard.compute_entries()

    assert first.rank == 1
    assert first.github_login == heavy.github_login
    assert first.total_tokens == 160

    assert second.rank == 2
    assert second.github_login == light.github_login
    assert second.total_tokens == 5
  end

  test "counts usage that reports no total_tokens" do
    # OpenAgents.Providers.Test omits total_tokens, and so may any other adapter. A
    # board that keyed on it alone would silently publish zero.
    user = account("no-total")

    complete_typed_turn(user, "No total reported.", %{
      "input_tokens" => 7,
      "output_tokens" => 5
    })

    assert [entry] = Leaderboard.compute_entries()
    assert entry.total_tokens == 12
  end

  test "counts a turn once even though provider steps carry their own usage" do
    user = account("single-count")

    conversation = conversation_for(user)
    %{turn: turn, receipt: receipt} = begin_typed_turn(conversation, "One turn, two steps.")

    # Both provider steps record usage of their own; the receipt carries their
    # merge. Summing both planes would double this account's total.
    {:ok, _first} =
      Conversations.record_provider_step_completion(receipt, "response-1", %{
        "input_tokens" => 10,
        "output_tokens" => 2,
        "total_tokens" => 12
      })

    {:ok, _turn} =
      Conversations.complete_turn(turn, "response-1", %{
        "input_tokens" => 10,
        "output_tokens" => 2,
        "total_tokens" => 12
      })

    assert [entry] = Leaderboard.compute_entries()
    assert entry.total_tokens == 12
  end

  test "omits accounts with no tokens" do
    silent = account("silent")
    {:ok, _conversation} = Conversations.ensure_conversation(silent)

    spoken = account("spoken")

    complete_typed_turn(spoken, "Say something.", %{
      "input_tokens" => 4,
      "output_tokens" => 1,
      "total_tokens" => 5
    })

    logins = Enum.map(Leaderboard.compute_entries(), & &1.github_login)

    assert logins == [spoken.github_login]
  end

  test "omits legacy browser visitors that belong to no account" do
    # DATA-002 keeps pre-authentication rows unclaimed; they have no account to
    # publish and must not surface as a phantom row.
    {:ok, conversation} = Conversations.ensure_conversation("legacy-browser-key")
    %{turn: turn} = begin_typed_turn(conversation, "Legacy browser turn.")

    {:ok, _turn} =
      Conversations.complete_turn(turn, "legacy-response", %{
        "input_tokens" => 50,
        "output_tokens" => 50,
        "total_tokens" => 100
      })

    assert Leaderboard.compute_entries() == []
  end

  test "omits banned accounts" do
    banned = account("banned")

    complete_typed_turn(banned, "Before the ban.", %{
      "input_tokens" => 90,
      "output_tokens" => 10,
      "total_tokens" => 100
    })

    assert [_entry] = Leaderboard.compute_entries()

    {:ok, _banned} = Accounts.ban_user(banned, "abuse")

    assert Leaderboard.compute_entries() == []
  end

  test "omits accounts that opted out of the public board" do
    user = account("withheld")

    complete_typed_turn(user, "Withhold me.", %{
      "input_tokens" => 60,
      "output_tokens" => 40,
      "total_tokens" => 100
    })

    assert [_entry] = Leaderboard.compute_entries()

    {:ok, _user} =
      user
      |> Ecto.Changeset.change(public_leaderboard_opted_out: true)
      |> Repo.update()

    assert Leaderboard.compute_entries() == []
  end

  test "drops an account from the board when it deletes its data" do
    user = account("erased")

    complete_typed_turn(user, "Delete this later.", %{
      "input_tokens" => 30,
      "output_tokens" => 20,
      "total_tokens" => 50
    })

    assert [_entry] = Leaderboard.compute_entries()

    conversation = conversation_for(user)
    owner = Repo.get_by!(OpenAgents.Conversations.Visitor, user_id: user.id)
    assert {:ok, :deleted} = DataRights.delete(user, owner, conversation)

    assert Leaderboard.compute_entries() == []
  end

  test "publishes at most the configured number of accounts" do
    for index <- 1..3 do
      index
      |> Integer.to_string()
      |> then(&account("capped-#{&1}"))
      |> complete_typed_turn("Turn #{index}.", %{
        "input_tokens" => index,
        "output_tokens" => index,
        "total_tokens" => index * 2
      })
    end

    assert length(Leaderboard.compute_entries(2)) == 2
  end

  test "publishes only the bounded projection" do
    user = account("bounded")

    record_voice_usage(user, "rtc-bounded", %{
      "input_tokens" => 12,
      "output_tokens" => 8,
      "total_tokens" => 20
    })

    assert [entry] = Leaderboard.compute_entries()

    # Voice usage carries a priced cost. Publishing per-account spend is a
    # separate product decision, so the struct cannot express it.
    assert Map.keys(entry) |> Enum.sort() == [
             :__struct__,
             :github_avatar_url,
             :github_login,
             :github_name,
             :rank,
             :total_tokens
           ]
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

  defp record_voice_usage(user, rtc_id, usage) do
    conversation = conversation_for(user)
    {:ok, session} = Voice.admit_session(conversation, voice_config())
    {:ok, session} = Voice.attach_provider(session, session.generation, rtc_id)

    events = [
      provider_event(:session_ready, "#{rtc_id}-ready", %{}),
      provider_event(:response_started, "#{rtc_id}-start", %{"response_id" => "voice-1"}),
      provider_event(:response_completed, "#{rtc_id}-done", %{
        "response_id" => "voice-1",
        "status" => "completed",
        "usage" => usage
      })
    ]

    Enum.reduce(events, session, fn event, current ->
      {:ok, updated, _persisted, :created} =
        Voice.record_provider_event(current, current.generation, event)

      updated
    end)
  end

  defp provider_event(kind, event_id, payload) do
    %ProviderEvent{kind: kind, provider_event_id: event_id, payload: payload}
  end

  defp voice_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end
end
