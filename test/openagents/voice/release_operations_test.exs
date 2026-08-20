defmodule OpenAgents.Voice.ReleaseOperationsTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip

  import ExUnit.CaptureLog

  alias OpenAgents.{Conversations, Repo, Voice}

  alias OpenAgents.Voice.{
    BrowserIdentity,
    Config,
    OperationalTelemetry,
    ReleaseControl,
    Retention,
    Session,
    Usage
  }

  alias OpenAgents.Voice.Operations.Report

  test "append-only release control drains new calls without ending active calls" do
    {:ok, conversation} = Conversations.ensure_conversation("release-control-active-browser")
    assert {:ok, active} = Voice.admit_session(conversation, enabled_config())
    assert active.release_control_id == ReleaseControl.current!().id

    assert {:ok, draining} =
             ReleaseControl.append(%{
               state: "draining",
               reason: "Canary investigation",
               actor: "release-test",
               source_revision: "test-revision"
             })

    assert ReleaseControl.current!().id == draining.id

    {:ok, second_conversation} =
      Conversations.ensure_conversation("release-control-refused-browser")

    assert {:error, :voice_draining} =
             Voice.admit_session(second_conversation, enabled_config())

    assert Voice.get_session!(active.id).status == "connecting"
    assert {:ok, ended} = Voice.end_session(active, active.generation, "test")
    assert ended.status == "ended"

    assert_raise Postgrex.Error, fn ->
      draining |> Ecto.Changeset.change(reason: "rewritten") |> Repo.update!()
    end

    assert_raise Postgrex.Error, fn -> Repo.delete!(draining) end
  end

  test "a serialized global cap bounds anonymous concurrent sessions" do
    previous = Application.fetch_env!(:openagents, :voice_maximum_concurrent_sessions)
    Application.put_env(:openagents, :voice_maximum_concurrent_sessions, 1)

    on_exit(fn ->
      Application.put_env(:openagents, :voice_maximum_concurrent_sessions, previous)
    end)

    {:ok, first_conversation} = Conversations.ensure_conversation("capacity-first-browser")
    {:ok, second_conversation} = Conversations.ensure_conversation("capacity-second-browser")

    assert {:ok, first} = Voice.admit_session(first_conversation, enabled_config())

    assert {:error, :voice_capacity_reached} =
             Voice.admit_session(second_conversation, enabled_config())

    assert {:ok, _ended} = Voice.end_session(first, first.generation, "test")
  end

  test "client observations are bounded and user agents reduce to a safe matrix" do
    {:ok, conversation} = Conversations.ensure_conversation("client-observation-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    assert BrowserIdentity.parse("Mozilla/5.0 Chrome/141.0.0.0 Safari/537.36") ==
             {"chrome", 141}

    assert BrowserIdentity.parse("private-unrecognized-agent") == {"other", nil}

    assert {:ok, event} =
             Voice.record_client_event(session, "peer_connected", {"chrome", 141})

    assert event.sequence == 1
    refute Map.has_key?(Map.from_struct(event), :payload)

    assert {:error, changeset} =
             Voice.record_client_event(session, "raw_microphone_chunk", {"chrome", 141})

    assert "is invalid" in errors_on(changeset).kind
  end

  test "operational retention removes detail and leaves only a provenance stub" do
    {:ok, conversation} = Conversations.ensure_conversation("retention-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    assert {:ok, session, _event, :created} =
             Voice.record_provider_event(session, session.generation, %Voice.ProviderEvent{
               kind: :session_ready,
               provider_event_id: "retention-ready",
               payload: %{}
             })

    assert {:ok, _client_event} =
             Voice.record_client_event(session, "peer_connected", {"safari", 19})

    assert {:ok, ended} = Voice.end_session(session, session.generation, "test")
    expired_at = DateTime.add(DateTime.utc_now(), -91, :day)

    {1, nil} =
      Repo.update_all(from(row in Session, where: row.id == ^ended.id),
        set: [ended_at: expired_at]
      )

    assert {:ok, 1} = Retention.purge_expired(DateTime.utc_now())
    purged = Repo.get!(Session, ended.id)
    assert purged.instructions == "[purged after operational retention]"
    assert purged.tool_catalog == %{"schema" => "sarah.realtime_tool_catalog.v1", "tools" => []}
    assert purged.provider_session_id == nil
    assert purged.operational_purged_at
    assert Voice.list_events(purged) == []
  end

  test "usage pricing preserves detailed counters and uses conservative unclassified rates" do
    detailed =
      Usage.normalize_provider(%{
        "input_tokens" => 12,
        "output_tokens" => 8,
        "total_tokens" => 20,
        "input_token_details" => %{
          "text_tokens" => 5,
          "audio_tokens" => 7,
          "cached_tokens" => 2,
          "cached_tokens_details" => %{"audio_tokens" => 2}
        },
        "output_token_details" => %{"text_tokens" => 2, "audio_tokens" => 6}
      })

    priced = Usage.price(detailed, "gpt-realtime-2.1")
    assert priced["input_cached_audio_tokens"] == 2
    assert priced["estimated_cost_microusd"] == 613

    conservative =
      %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}
      |> Usage.price("gpt-realtime-2.1")

    assert conservative["input_unclassified_tokens"] == 12
    assert conservative["output_unclassified_tokens"] == 8
    assert conservative["estimated_cost_microusd"] == 896
  end

  test "aggregate release report exposes indicators and never transcript content" do
    private_words = "private spoken report marker"
    {:ok, conversation} = Conversations.ensure_conversation("release-report-browser")
    {:ok, session} = Voice.admit_session(conversation, enabled_config())

    assert {:ok, listening, _event, :created} =
             Voice.record_provider_event(session, session.generation, %Voice.ProviderEvent{
               kind: :session_ready,
               provider_event_id: "report-ready",
               payload: %{}
             })

    assert {:ok, _client_event} =
             Voice.record_client_event(listening, "peer_connected", {"chrome", 141})

    assert {:ok, _client_event} =
             Voice.record_client_event(listening, "first_remote_track", {"chrome", 141})

    assert {:ok, listening, _event, :created} =
             Voice.record_provider_event(listening, listening.generation, %Voice.ProviderEvent{
               kind: :user_transcript_final,
               provider_event_id: "report-private-transcript",
               payload: %{
                 "item_id" => "report-user-item",
                 "response_id" => nil,
                 "content" => private_words
               }
             })

    assert {:ok, _ended} = Voice.end_session(listening, listening.generation, "test")

    report = Report.build(DateTime.add(DateTime.utc_now(), -1, :hour))
    assert report["counts"]["attempts"] == 1
    assert report["counts"]["connected"] == 1
    assert report["latency_ms"]["first_remote_audio"]["samples"] == 1
    assert report["usage"]["sessions_reported"] == 0

    assert report["browser_matrix"] == [
             %{"connections" => 1, "family" => "chrome", "major" => 141}
           ]

    assert report["gate"]["decision"] == "hold"
    assert "at_least_10_response_start_samples" in report["gate"]["failures"]
    assert "at_least_10_provider_usage_samples" in report["gate"]["failures"]
    refute inspect(report) =~ private_words

    assert Report.distribution([10, 20, 30, 40]) == %{
             "samples" => 4,
             "p50" => 20,
             "p95" => 40,
             "p99" => 40,
             "maximum" => 40
           }
  end

  test "operational logs cannot include transcripts, SDP, credentials, or tool arguments" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    secret = "sk-private voice transcript v=0 raw-tool-argument"

    session = %Session{
      id: Ecto.UUID.generate(),
      generation: 1,
      status: "failed",
      model_id: "gpt-realtime-2.1",
      voice_artifact_id: "sarah.voice.openai.marin.v1",
      failure_code: "provider_error",
      instructions: secret,
      usage: %{"total_tokens" => 5, "estimated_cost_microusd" => 10}
    }

    log =
      capture_log(fn ->
        assert :ok =
                 OperationalTelemetry.emit(:session_terminal, session, %{
                   event_kind: "provider_error",
                   raw_arguments: secret,
                   transcript: secret,
                   sdp: secret
                 })
      end)

    assert log =~ "sarah.voice_operation.v1"
    refute log =~ secret
    refute log =~ "raw_arguments"
    refute log =~ "transcript"
    refute log =~ "sdp"
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
