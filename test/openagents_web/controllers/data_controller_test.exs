defmodule OpenAgentsWeb.DataControllerTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations.Message
  alias OpenAgents.ExperienceMemory.DeletionReceipt, as: ExperienceDeletionReceipt

  alias OpenAgents.GraphMemory.{
    CascadePlan,
    Manifest,
    OperationReceipt,
    OutboxEvent,
    SourceMembership
  }

  alias OpenAgents.Memory.SemanticDerivativeReceipt
  alias OpenAgents.Preferences.{ActivationReceipt, Observation, Preference, SnapshotRecord}
  alias OpenAgents.Provenance.Canonical

  alias OpenAgents.{
    ApiTokens,
    Conversations,
    ExperienceMemory,
    GraphMemory,
    Preferences,
    ProfileMemory,
    Repo
  }

  setup do
    original = Application.fetch_env!(:openagents, :graph_memory)
    Application.put_env(:openagents, :graph_memory, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:openagents, :graph_memory, original) end)
    :ok
  end

  test "account owner can export conversation, memory, and voice disclosure", %{conn: conn} do
    token = "data-export-browser-credential-00000000000000000"
    user = github_user(token)
    assert {:ok, user} = OpenAgents.Accounts.store_github_token(user, "gho_export_sentinel")

    assert {:ok, api_credential, api_plaintext} =
             ApiTokens.create(user, %{
               name: "export metadata",
               scopes: ["forge:write"],
               lifetime_days: 7
             })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    source =
      Repo.insert!(%OpenAgents.Conversations.Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Remember that export tests should stay bounded.",
        status: "complete"
      })

    assert {:ok, _memory} =
             ProfileMemory.remember_explicit(owner, %{
               category: "preference",
               claim: "Keep export tests bounded.",
               creator: "user_explicit",
               sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}],
               provenance: %{"operation" => "test"}
             })

    conn =
      conn
      |> log_in_github_user(token)
      |> get(~p"/data/export")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "sarah-account-data.json"

    export = json_response(conn, 200)
    assert export["schema"] == "sarah.account_data_export.v1"
    assert export["scope"] == "authenticated_github_user"
    assert Enum.any?(export["messages"], &(&1["role"] == "assistant"))
    assert [%{"claim" => "Keep export tests bounded."}] = export["profile_memory"]["records"]
    assert export["voice_sessions"] == []
    assert [exported_api_credential] = export["api_credentials"]
    assert exported_api_credential["id"] == api_credential.id
    assert exported_api_credential["name"] == "export metadata"
    assert exported_api_credential["scopes"] == ["forge:write"]
    assert exported_api_credential["credential_exported"] == false

    assert export["github_connection"] == %{
             "connected" => true,
             "connected_at" => DateTime.to_iso8601(user.github_token_connected_at),
             "credential_exported" => false,
             "product_data_deletion" => "retained_until_explicit_disconnect",
             "rotated_at" => nil,
             "scopes" => ["repo", "read:org"]
           }

    refute inspect(export) =~ "gho_export_sentinel"
    refute inspect(export) =~ api_plaintext
    refute inspect(export) =~ user.id
  end

  test "exact confirmation deletes product data while retaining account authority", %{
    conn: conn
  } do
    token = "data-delete-browser-credential-00000000000000000"
    user = github_user(token)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    receipt =
      Repo.insert!(%SemanticDerivativeReceipt{
        message_id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        content_digest: String.duplicate("a", 64),
        action: "delete",
        reason_code: "owner_privacy_delete",
        generation: 1,
        deleted_embedding_count: 1,
        invalidated_job_count: 1,
        receipt_digest: String.duplicate("b", 64)
      })

    assert_raise Postgrex.Error, fn -> Repo.delete!(receipt) end

    preference_records = active_preference(owner, conversation)

    assert_raise Postgrex.Error, fn ->
      Repo.delete!(preference_records.activation)
    end

    experience_receipt =
      Repo.insert!(%ExperienceDeletionReceipt{
        owner_visitor_id: owner.id,
        work_scope: "conversation:#{conversation.id}",
        record_ref: "experience:v1:#{Ecto.UUID.generate()}",
        source_ref_count: 1,
        bank_item_count: 1,
        pattern_count: 0,
        reason_code: "owner_deleted",
        receipt_digest: String.duplicate("c", 64)
      })

    assert_raise Postgrex.Error, fn -> Repo.delete!(experience_receipt) end

    graph_records = active_graph(owner, conversation)

    assert_raise Postgrex.Error, fn ->
      Repo.delete!(graph_records.operation_receipt)
    end

    conn = log_in_github_user(conn, token)

    refused = delete_data(conn, "delete it")
    assert response(refused, 422) =~ "Type DELETE MY SARAH DATA exactly"
    assert Repo.get(OpenAgents.Conversations.Visitor, owner.id)

    deleted =
      conn
      |> recycle()
      |> log_in_github_user(token)
      |> delete_data("DELETE MY SARAH DATA")

    assert redirected_to(deleted) == ~p"/chat"
    assert get_session(deleted, "user_id") == user.id

    assert Repo.get(OpenAgents.Conversations.Visitor, owner.id) == nil
    assert Conversations.get_conversation_for_user(user) == nil
    assert Repo.get(OpenAgents.Accounts.User, user.id)
    assert Repo.get(SemanticDerivativeReceipt, receipt.id) == nil
    assert Repo.get(Observation, preference_records.observation.id) == nil
    assert Repo.get(Preference, preference_records.preference.id) == nil
    assert Repo.get(ActivationReceipt, preference_records.activation.id) == nil
    assert Repo.get(SnapshotRecord, preference_records.snapshot_id) == nil
    assert Repo.get(ExperienceDeletionReceipt, experience_receipt.id) == nil
    assert Repo.get(Manifest, graph_records.manifest_id) == nil
    assert Repo.get(SourceMembership, graph_records.membership_id) == nil
    assert Repo.get(OutboxEvent, graph_records.outbox_event_id) == nil
    assert Repo.get(CascadePlan, graph_records.cascade_plan_id) == nil
    assert Repo.get(OperationReceipt, graph_records.operation_receipt.id) == nil
  end

  test "privacy controls state audio, transcript, retention, export, and deletion behavior", %{
    conn: conn
  } do
    conn = log_in_github_user(conn, "privacy-controls-browser")
    # Memory is its own page now, reached from the sidebar rather than by
    # swapping the transcript out from under the reader.
    assert {:ok, view, _html} = live(conn, ~p"/memory")
    html = render(view)

    assert html =~ "Detailed operational voice evidence is purged after 90 days"
    refute html =~ "never stored"
    assert html =~ "Detailed operational voice"
    assert html =~ "evidence is purged after 90 days"
    assert html =~ ~s(id="export-all-data")
    assert html =~ ~s(id="delete-all-data")
    assert html =~ "DELETE MY SARAH DATA"

    # Recording is stated where deletion is stated, so the person reading about
    # deletion learns what there is to delete.
    assert html =~ ~s(id="privacy-recording")
    assert html =~ "readable by a Sarah operator"
    assert html =~ "#{OpenAgents.Voice.Recordings.config().retention_days} days after a call ends"
  end

  test "the export names the call's audio and deletion removes it", %{conn: conn} do
    token = "data-recording-export-browser"
    user = github_user(token)
    conn = log_in_github_user(conn, token)

    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    {:ok, session} = OpenAgents.Voice.admit_session(conversation, enabled_voice_config())

    {:ok, _chunk} =
      OpenAgents.Voice.Recordings.append_chunk(
        session,
        session.generation,
        1,
        "opus-bytes",
        "audio/webm;codecs=opus"
      )

    {:ok, _closed} =
      OpenAgents.Voice.Recordings.finalize(session, session.generation, "complete", 6_000)

    {:ok, _ended} = OpenAgents.Voice.end_session(session, session.generation, "user_ended")

    export = conn |> get(~p"/data/export") |> response(200) |> Jason.decode!()
    [voice_session] = export["voice_sessions"]

    # The bytes are not embedded — a JSON export is the wrong container for Opus —
    # but the account is told the audio exists, how large it is, and that it is
    # encrypted at rest.
    assert voice_session["recording"]["status"] == "complete"
    assert voice_session["recording"]["byte_size"] == 10
    assert voice_session["recording"]["encrypted_at_rest"] == true
    assert voice_session["recording"]["client_duration_ms"] == 6_000
    refute export |> Jason.encode!() =~ "opus-bytes"

    delete(conn, ~p"/data", %{"privacy" => %{"confirmation" => "DELETE MY SARAH DATA"}})

    assert Repo.aggregate(OpenAgents.Voice.Recording, :count) == 0
    assert Repo.aggregate(OpenAgents.Voice.RecordingChunk, :count) == 0
  end

  defp enabled_voice_config do
    OpenAgents.Voice.Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end

  test "one-click reset deletes messages and memories when the control is enabled", %{
    conn: conn
  } do
    original = Application.get_env(:openagents, :conversation_reset_enabled, false)
    Application.put_env(:openagents, :conversation_reset_enabled, true)
    on_exit(fn -> Application.put_env(:openagents, :conversation_reset_enabled, original) end)

    token = "data-reset-browser-credential-000000000000000000"
    user = github_user(token)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    other_user = github_user("data-reset-other-browser-credential-0000000000000")
    {:ok, other_conversation} = Conversations.ensure_conversation(other_user)
    other_owner = Conversations.get_conversation_owner!(other_conversation)

    source =
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Remember that resets should wipe everything.",
        status: "complete"
      })

    assert {:ok, _memory} =
             ProfileMemory.remember_explicit(owner, %{
               category: "preference",
               claim: "Wipe everything on reset.",
               creator: "user_explicit",
               sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}],
               provenance: %{"operation" => "test"}
             })

    reset =
      conn
      |> log_in_github_user(token)
      |> reset_data()

    assert redirected_to(reset) == ~p"/chat"
    assert get_session(reset, "user_id") == user.id

    assert Repo.get(OpenAgents.Conversations.Visitor, owner.id) == nil
    assert Conversations.get_conversation_for_user(user) == nil
    assert Repo.get(Message, source.id) == nil
    assert Repo.get(OpenAgents.Accounts.User, user.id)

    assert Repo.get(OpenAgents.Conversations.Visitor, other_owner.id)
    assert Conversations.get_conversation_for_user(other_user)
  end

  test "one-click reset is refused when the control is disabled", %{conn: conn} do
    original = Application.get_env(:openagents, :conversation_reset_enabled, false)
    Application.put_env(:openagents, :conversation_reset_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :conversation_reset_enabled, original) end)

    token = "data-reset-disabled-browser-credential-0000000000"
    user = github_user(token)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    refused =
      conn
      |> log_in_github_user(token)
      |> reset_data()

    assert response(refused, 404)
    assert Repo.get(OpenAgents.Conversations.Visitor, owner.id)
    assert Conversations.get_conversation_for_user(user).id == conversation.id
  end

  defp reset_data(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_req_header("accept", "text/html")
    |> put_req_header("x-csrf-token", csrf_token)
    |> delete(~p"/data/reset")
  end

  defp delete_data(conn, confirmation) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_req_header("accept", "text/html")
    |> put_req_header("x-csrf-token", csrf_token)
    |> delete(~p"/data", %{"privacy" => %{"confirmation" => confirmation}})
  end

  defp active_preference(owner, conversation) do
    source =
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Please keep answers concise.",
        status: "complete"
      })

    proposer_id = "sarah.preference.privacy-test"

    assert {:ok, observation} =
             Preferences.observe(owner, %{
               "source_kind" => "current_user_message",
               "source_message_id" => source.id,
               "summary" => "Explicit concise-answer preference.",
               "confidence_millis" => 900,
               "freshness_until" => DateTime.add(DateTime.utc_now(), 86_400, :second),
               "proposer_id" => proposer_id,
               "proposer_digest" => Canonical.sha256(proposer_id)
             })

    assert {:ok, candidate} =
             Preferences.propose(owner, observation.id, "response_length", "concise")

    assert {:ok, %{preference: reviewed}} =
             Preferences.review(owner, candidate.id, candidate.generation, %{
               "reviewer_id" => "host-policy:privacy-test",
               "decision" => "accepted",
               "reason_code" => "effect_allowlisted"
             })

    assert {:ok, confirmed} =
             Preferences.confirm(owner, reviewed.id, reviewed.generation, %{
               "kind" => "first_party_ui",
               "effect_digest" => reviewed.effect_digest,
               "ref" => "preference-panel:privacy-test"
             })

    assert {:ok, %{preference: preference, receipt: activation}} =
             Preferences.activate(owner, confirmed.id, confirmed.generation)

    assert {:ok, snapshot} = Preferences.capture_snapshot(owner)
    "preference-snapshot:v1:" <> snapshot_id = snapshot.ref

    %{
      observation: observation,
      preference: preference,
      activation: activation,
      snapshot_id: snapshot_id
    }
  end

  defp active_graph(owner, conversation) do
    source =
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        content: "The privacy graph must remain derived and owner-scoped.",
        status: "complete"
      })

    work_scope = "conversation:#{conversation.id}"

    assert {:ok, record} =
             ExperienceMemory.create_case(owner, work_scope, %{
               "objective" => "Verify complete owner-root deletion",
               "approach" => "Build a derived graph from bounded failed experience",
               "applicability" => "Only this browser-owned privacy test",
               "confidence_millis" => 700,
               "source_refs" => ["message:#{source.id}"],
               "trace_refs" => []
             })

    assert {:ok, running} =
             ExperienceMemory.start_case(owner, record.id, record.generation)

    assert {:ok, failed} =
             ExperienceMemory.complete_case(owner, running.id, running.generation, %{
               "outcome_state" => "failed",
               "outcome" => "The test retains failure as bounded evidence.",
               "target_receipt_refs" => []
             })

    assert {:ok, build} = GraphMemory.rebuild(owner, work_scope)

    assert {:ok, plan} =
             GraphMemory.plan_cascade(owner, work_scope, "experience:#{failed.id}")

    membership =
      Repo.one!(
        from(membership in SourceMembership,
          where: membership.owner_visitor_id == ^owner.id,
          limit: 1
        )
      )

    outbox_event =
      Repo.one!(
        from(event in OutboxEvent,
          where: event.owner_visitor_id == ^owner.id,
          limit: 1
        )
      )

    operation_receipt =
      Repo.one!(
        from(receipt in OperationReceipt,
          where: receipt.owner_visitor_id == ^owner.id,
          limit: 1
        )
      )

    %{
      manifest_id: build.manifest.id,
      membership_id: membership.id,
      outbox_event_id: outbox_event.id,
      cascade_plan_id: plan.id,
      operation_receipt: operation_receipt
    }
  end
end
