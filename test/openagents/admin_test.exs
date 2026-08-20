defmodule OpenAgents.AdminTest do
  @moduledoc """
  `OpenAgents.Admin` is the second deliberate exception to IDENTITY-002. These assert
  the shape of that exception: what the projection carries, that it is read-only,
  and that a call with no audio is still a row.
  """

  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Accounts
  alias OpenAgents.Admin
  alias OpenAgents.Admin.Call
  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  test "lists calls across accounts, newest first, with their audio" do
    older = call_for("admin-context-older")
    newer = call_for("admin-context-newer")

    {:ok, _chunk} = Recordings.append_chunk(newer, newer.generation, 1, "opus", @webm)
    {:ok, _closed} = Recordings.finalize(newer, newer.generation, "complete", 5_000)

    # Two different accounts, one list: the exception is the point of the module.
    assert [first, second] = Admin.list_calls()
    assert first.session_id == newer.id
    assert second.session_id == older.id

    assert Call.playable?(first)
    assert first.recording.byte_size == 4
    assert first.recording.chunk_count == 1
    assert first.recording.status == "complete"
    assert first.recording.sealed

    refute Call.playable?(second)
    assert second.recording == nil
    assert Call.absence_reason(second) =~ "No audio uploaded"
  end

  test "the projection carries no private call material" do
    session = call_for("admin-context-private")
    {:ok, _attached} = Voice.attach_provider(session, session.generation, "rtc_admin_context")

    [call] = Admin.list_calls()

    # The struct is the contract, the same way Leaderboard.Entry is. Provider call
    # identity, composed instructions, tool catalogs, and priced cost are absent
    # by construction rather than by remembering not to render them.
    assert Map.keys(Map.from_struct(call)) |> Enum.sort() == [
             :ended_at,
             :failure_code,
             :generation,
             :github_avatar_url,
             :github_login,
             :github_name,
             :model_id,
             :recording,
             :session_id,
             :started_at,
             :status,
             :termination_reason,
             :total_tokens,
             :transcript_item_count,
             :voice_artifact_id
           ]
  end

  test "counts transcript items without reading their content" do
    session = call_for("admin-context-transcript")
    {:ok, session} = Voice.attach_provider(session, session.generation, "rtc_admin_count")

    {:ok, session, _event, :created} =
      Voice.record_provider_event(session, session.generation, %OpenAgents.Voice.ProviderEvent{
        kind: :session_ready,
        provider_event_id: "evt-count-ready",
        payload: %{}
      })

    {:ok, _session, _event, :created} =
      Voice.record_provider_event(session, session.generation, %OpenAgents.Voice.ProviderEvent{
        kind: :user_transcript_final,
        provider_event_id: "evt-count-user",
        payload: %{"item_id" => "item-count", "response_id" => nil, "content" => "secret words"}
      })

    [call] = Admin.list_calls()
    assert call.transcript_item_count == 1
  end

  test "legacy browser-only visitors never appear, because they have no account" do
    {:ok, conversation} = Conversations.ensure_conversation("admin-context-browser-only")
    {:ok, _session} = Voice.admit_session(conversation, enabled_config())

    assert Admin.list_calls() == []
    assert Admin.count_calls() == 0
  end

  test "totals are content-free counters" do
    session = call_for("admin-context-totals")
    {:ok, _chunk} = Recordings.append_chunk(session, session.generation, 1, "opus-bytes", @webm)

    assert Admin.recording_totals() == %{calls: 1, recorded: 1, byte_size: 10}
  end

  test "paging is bounded and cannot be widened past the ceiling" do
    for index <- 1..3, do: call_for("admin-context-page-#{index}")

    assert length(Admin.list_calls(limit: 2)) == 2
    assert length(Admin.list_calls(limit: 2, offset: 2)) == 1
    assert length(Admin.list_calls(limit: 10_000)) == 3
    assert length(Admin.list_calls(limit: -5)) == 3
  end

  test "a token total survives usage that reports no total" do
    session = call_for("admin-context-usage")

    session
    |> Ecto.Changeset.change(%{usage: %{"input_tokens" => 12, "output_tokens" => 8}})
    |> OpenAgents.Repo.update!()

    assert [%Call{total_tokens: 20}] = Admin.list_calls()
  end

  test "get_recording/1 refuses a malformed identifier instead of raising" do
    assert {:error, :not_found} = Admin.get_recording("not-a-uuid")
    assert {:error, :not_found} = Admin.get_recording(Ecto.UUID.generate())
  end

  test "operator access is matched on the immutable GitHub id" do
    user = github_user("admin-context-operator")

    refute Accounts.admin?(user)
    refute Accounts.admin?(nil)

    original = Application.get_env(:openagents, :admin_github_ids, [])

    try do
      Application.put_env(:openagents, :admin_github_ids, [user.github_id])
      assert Accounts.admin?(user)

      # A banned account is never an operator, whatever the allowlist says.
      {:ok, banned} = Accounts.ban_user(user, "policy")
      refute Accounts.admin?(banned)

      # A login string grants nothing.
      Application.put_env(:openagents, :admin_github_ids, [user.github_login])
      refute Accounts.admin?(%{user | status: "active"})
    after
      Application.put_env(:openagents, :admin_github_ids, original)
    end
  end

  defp call_for(key) do
    {:ok, conversation} = Conversations.ensure_conversation(github_user(key))
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    session
  end

  defp github_user(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{Base.encode16(digest, case: :lower) |> binary_part(0, 10)}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp enabled_config do
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
