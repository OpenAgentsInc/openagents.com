defmodule OpenAgents.PreferencesTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.{Context.Composer, Conversations, Preferences}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Providers.Request
  alias OpenAgents.Provenance.Canonical

  test "observations and confidence cannot bypass review, exact confirmation, or activation receipts" do
    {owner, conversation} = owner_conversation("preference-lifecycle")
    source = message(conversation, "I prefer concise answers.")
    observation = observe(owner, source, "Observed an explicit concise-answer preference.")

    assert {:error, :effect_not_admitted} =
             Preferences.propose(owner, observation.id, "tool_authority", "grant")

    assert {:ok, candidate} =
             Preferences.propose(owner, observation.id, "response_length", "concise")

    assert candidate.status == "candidate"
    assert {:error, :invalid_transition} = Preferences.activate(owner, candidate.id, 1)

    assert {:error, :invalid_reviewer} =
             Preferences.review(owner, candidate.id, 1, %{
               "reviewer_id" => "model:self-approved",
               "decision" => "accepted",
               "reason_code" => "self_approval"
             })

    assert {:ok, snapshot_before_review} = Preferences.capture_snapshot(owner)

    assert {:ok, %{applied: []}} =
             Preferences.project_active(owner, snapshot_before_review, "Hello")

    assert {:ok, %{preference: reviewed, receipt: review_receipt}} =
             Preferences.review(owner, candidate.id, 1, %{
               "reviewer_id" => "host-policy:test",
               "decision" => "accepted",
               "reason_code" => "effect_allowlisted"
             })

    assert reviewed.status == "reviewed"
    refute inspect(review_receipt) =~ source.content

    assert {:error, :confirmation_mismatch} =
             Preferences.confirm(owner, reviewed.id, 2, %{
               "kind" => "first_party_ui",
               "effect_digest" => String.duplicate("0", 64),
               "ref" => "preference-panel:test"
             })

    assert {:ok, confirmed} =
             Preferences.confirm(owner, reviewed.id, 2, confirmation(reviewed))

    assert confirmed.status == "confirmed"

    assert {:ok, %{preference: active, receipt: activation}} =
             Preferences.activate(owner, confirmed.id, 3)

    assert active.status == "active"
    assert activation.effect_digest == active.effect_digest
    assert activation.confirmation_ref == active.confirmation_ref

    assert {:ok, snapshot} = Preferences.capture_snapshot(owner)
    assert {:ok, normal} = Preferences.project_active(owner, snapshot, "Explain this")
    assert [applied] = normal.applied
    assert applied["effect"] == %{"key" => "response_length", "value" => "concise"}
    assert [usage] = normal.usage["applied"]
    assert usage["preference_ref"] == "preference:v1:#{active.id}"
    assert usage["activation_receipt_ref"] == "preference-activation:v1:#{activation.id}"

    assert {:ok, overridden} =
             Preferences.project_active(owner, snapshot, "Give me a detailed, in-depth answer")

    assert overridden.applied == []
    assert [override] = overridden.usage["overridden"]
    assert override["reason"] == "current_instruction"
  end

  test "snapshots are owner confined and suspension, correction, and deletion remove later effects" do
    {owner, conversation} = owner_conversation("preference-snapshots")
    {foreign_owner, _foreign_conversation} = owner_conversation("preference-foreign")
    source = message(conversation, "Use bullet points by default.")
    active = activate_preference(owner, source, "format", "bullets")

    assert {:ok, before_suspend} = Preferences.capture_snapshot(owner)

    assert {:error, :scope_refused} =
             Preferences.project_active(foreign_owner, before_suspend, "Anything")

    correction_source = message(conversation, "Actually use paragraphs by default.")

    assert {:ok, %{suspended: suspended, candidate: replacement}} =
             Preferences.correct(
               owner,
               active.id,
               active.generation,
               observation_attributes(
                 correction_source,
                 "Correction from bullets to paragraphs.",
                 "correction"
               ),
               "format",
               "paragraphs"
             )

    assert suspended.status == "suspended"
    assert replacement.status == "candidate"
    assert replacement.supersedes_preference_id == active.id

    assert {:ok, historical} = Preferences.project_active(owner, before_suspend, "Anything")
    assert [%{"effect" => %{"value" => "bullets"}}] = historical.applied

    assert {:ok, after_correction} = Preferences.capture_snapshot(owner)

    assert {:ok, %{applied: []}} =
             Preferences.project_active(owner, after_correction, "Anything")

    assert {:ok, deleted} =
             Preferences.delete(owner, replacement.id, replacement.generation, "owner_deleted")

    assert deleted.status == "deleted"
    assert {:ok, all} = Preferences.inspect_all(owner)
    assert Enum.map(all, & &1.status) == ["suspended", "deleted"]
  end

  test "turn capture freezes applied preferences and outcomes require that exact activation" do
    {owner, conversation} = owner_conversation("preference-turn")
    source = message(conversation, "Please give concise answers.")
    active = activate_preference(owner, source, "response_length", "concise")
    assert {:ok, snapshot} = Preferences.capture_snapshot(owner)
    assert {:ok, projection} = Preferences.project_active(owner, snapshot, "What changed?")

    assert {:ok, records} = Conversations.create_turn(conversation, "What changed?")

    context = Composer.compose!(preferences: projection.applied)

    request = %Request{
      model_id: "preference-test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id),
      tool_definitions: []
    }

    assert {:error, :invalid_preference_capture} =
             Conversations.begin_inference(
               records.turn,
               context,
               request,
               "preference.test"
             )

    assert {:ok, %{receipt: receipt}} =
             Conversations.begin_inference(records.turn, context, request, "preference.test",
               preference_snapshot_ref: snapshot.ref,
               preference_usage: projection.usage
             )

    assert receipt.preference_snapshot_ref == snapshot.ref
    assert receipt.used_preferences == projection.usage

    assert {:ok, outcome} =
             Preferences.record_outcome(owner, active.id, records.turn.id, %{
               "outcome" => "benefited",
               "evidence_ref" => "user-feedback:test",
               "reason_code" => "accepted_concise_response"
             })

    assert outcome.outcome == "benefited"
    assert outcome.activation_receipt_id

    assert_raise Postgrex.Error, fn ->
      receipt
      |> Ecto.Changeset.change(used_preferences: empty_usage())
      |> Repo.update!()
    end
  end

  test "committed benefit comparison preserves authority and current-turn override" do
    {owner, conversation} = owner_conversation("preference-benefit-eval")
    source = message(conversation, "I prefer concise answers.")
    _active = activate_preference(owner, source, "response_length", "concise")
    assert {:ok, snapshot} = Preferences.capture_snapshot(owner)
    assert {:ok, memory_on} = Preferences.project_active(owner, snapshot, "Explain the result")

    assert {:ok, overridden} =
             Preferences.project_active(owner, snapshot, "Give a detailed answer")

    off_context = Composer.compose!()
    on_context = Composer.compose!(preferences: memory_on.applied)

    measured = %{
      "authority_identity_preserved" =>
        score(
          off_context.persona_id == on_context.persona_id and
            off_context.role_id == on_context.role_id and
            off_context.role_digest == on_context.role_digest
        ),
      "confirmed_effect_applied" => score(on_context.instructions =~ ~s("value":"concise")),
      "current_instruction_override" => score(overridden.applied == []),
      "memory_off_difference" =>
        score(off_context.instruction_digest != on_context.instruction_digest)
    }

    expected =
      :openagents
      |> :code.priv_dir()
      |> Path.join("sarah/evals/preferences/benefit-comparison.v1.json")
      |> File.read!()
      |> Jason.decode!()

    assert measured == expected["metrics"]
  end

  defp activate_preference(owner, source, key, value) do
    observation = observe(owner, source, "Explicit #{key} preference for #{value}.")
    assert {:ok, candidate} = Preferences.propose(owner, observation.id, key, value)

    assert {:ok, %{preference: reviewed}} =
             Preferences.review(owner, candidate.id, candidate.generation, %{
               "reviewer_id" => "host-policy:test",
               "decision" => "accepted",
               "reason_code" => "effect_allowlisted"
             })

    assert {:ok, confirmed} =
             Preferences.confirm(owner, reviewed.id, reviewed.generation, confirmation(reviewed))

    assert {:ok, %{preference: active}} =
             Preferences.activate(owner, confirmed.id, confirmed.generation)

    active
  end

  defp observe(owner, source, summary) do
    assert {:ok, observation} =
             Preferences.observe(
               owner,
               observation_attributes(source, summary, "current_user_message")
             )

    observation
  end

  defp observation_attributes(source, summary, kind) do
    %{
      "source_kind" => kind,
      "source_message_id" => source.id,
      "summary" => summary,
      "confidence_millis" => 900,
      "freshness_until" => DateTime.add(DateTime.utc_now(), 86_400, :second),
      "proposer_id" => "sarah.preference.observer.test",
      "proposer_digest" => Canonical.sha256("sarah.preference.observer.test")
    }
  end

  defp confirmation(preference) do
    %{
      "kind" => "first_party_ui",
      "effect_digest" => preference.effect_digest,
      "ref" => "preference-panel:#{Ecto.UUID.generate()}"
    }
  end

  defp owner_conversation(key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(key)
    {Conversations.get_conversation_owner!(conversation), conversation}
  end

  defp message(conversation, content) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: "user",
      content: content,
      status: "complete"
    })
  end

  defp score(true), do: 1.0
  defp score(false), do: 0.0

  defp empty_usage,
    do: %{"schema" => "sarah.preference_usage.v1", "applied" => [], "overridden" => []}
end
