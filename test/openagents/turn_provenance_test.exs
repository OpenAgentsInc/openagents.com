defmodule OpenAgents.TurnProvenanceTest do
  use OpenAgents.SarahDataCase
  alias OpenAgents.{Context.Composer, Conversations, Turns}
  alias OpenAgents.Conversations.{ProviderStep, TurnReceipt}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Providers.Request

  test "captures immutable identity before provider work starts" do
    %{request: request, context: context, receipt: receipt, provider_step: step, turn: turn} =
      begin_turn("capture-browser", "Explain this.")

    assert turn.status == "streaming"
    assert receipt.status == "captured"
    assert receipt.schema_version == 1
    assert receipt.model_id == request.model_id
    assert receipt.persona_id == context.persona_id
    assert receipt.persona_digest == context.persona_digest
    assert receipt.role_id == context.role_id
    assert receipt.role_digest == context.role_digest
    assert receipt.role_selection == context.role_selection
    assert receipt.role_selection["schema"] == "sarah.role_selection.v1"
    assert receipt.role_selection["reason"] == "public_default"
    assert receipt.role_selection["surface"] == "text"
    assert receipt.instruction_digest == context.instruction_digest
    assert receipt.input_digest == Canonical.digest!(request.input)
    assert receipt.input_message_count == length(request.input)
    assert receipt.input_bytes == byte_size(Canonical.encode!(request.input))
    assert receipt.used_source_refs == []
    assert receipt.used_tool_step_refs == []

    assert receipt.used_memory_evidence == %{
             "schema" => "sarah.memory_evidence_usage.v1",
             "items" => []
           }

    assert receipt.tool_catalog_digest == nil
    assert receipt.blueprint_revision == nil
    assert receipt.program_artifact_id == "sarah.program.memory_intent.shadow.v1"
    assert byte_size(receipt.program_artifact_digest) == 64
    assert receipt.program_artifact_receipt["schema"] == "sarah.program_capture.v1"
    refute receipt.program_artifact_receipt["degraded"]
    assert receipt.memory_snapshot_ref =~ ~r/^message:[0-9a-f-]{36}$/
    assert step.sequence == 1
    assert step.provider_id == "test.provider"
    assert step.model_id == request.model_id
    assert step.status == "started"
  end

  test "reconstructs ordered provider responses, usage, and used references" do
    %{receipt: receipt, turn: turn} = begin_turn("chain-browser", "Use two provider steps.")

    assert {:ok, completed_first_step} =
             Conversations.record_provider_step_completion(
               receipt,
               "response-1",
               %{"input_tokens" => 10, "output_tokens" => 2}
             )

    assert completed_first_step.sequence == 1

    assert {:ok, second_step} =
             Conversations.start_provider_step(receipt, "test.provider", "model-v2")

    assert second_step.sequence == 2

    assert {:ok, updated_receipt} =
             Conversations.record_used_refs(receipt,
               source_refs: ["message:2", "message:1", "message:1"],
               tool_step_refs: ["tool-step:1"]
             )

    assert updated_receipt.used_source_refs == ["message:1", "message:2"]
    assert updated_receipt.used_tool_step_refs == ["tool-step:1"]

    assert {:ok, completed_turn} =
             Conversations.complete_turn(
               turn,
               "response-2",
               %{"input_tokens" => 4, "output_tokens" => 8}
             )

    assert completed_turn.status == "completed"
    assert {:ok, terminal_receipt} = Conversations.get_turn_receipt(completed_turn)
    assert terminal_receipt.status == "completed"
    assert terminal_receipt.provider_completed_at
    assert terminal_receipt.usage == %{"input_tokens" => 4, "output_tokens" => 8}

    assert [first_step, terminal_second_step] =
             Conversations.list_provider_steps(terminal_receipt)

    assert first_step.provider_response_id == "response-1"
    assert first_step.usage == %{"input_tokens" => 10, "output_tokens" => 2}
    assert terminal_second_step.sequence == 2
    assert terminal_second_step.provider_response_id == "response-2"
    assert terminal_second_step.status == "completed"

    assert {:error, :turn_receipt_is_terminal} =
             Conversations.record_used_refs(terminal_receipt,
               source_refs: ["message:after-terminal"]
             )
  end

  test "host failure after a completed provider response preserves that response step" do
    %{receipt: receipt, turn: turn} = begin_turn("host-failure-browser", "Finish provider first.")

    assert {:ok, %ProviderStep{status: "completed"}} =
             Conversations.record_provider_step_completion(receipt, "provider-finished")

    assert {:ok, failed_turn} = Conversations.fail_turn(turn, :host_persistence_failed)
    assert {:ok, failed_receipt} = Conversations.get_turn_receipt(failed_turn)
    assert failed_receipt.status == "failed"

    assert [%ProviderStep{status: "completed", provider_response_id: "provider-finished"}] =
             Conversations.list_provider_steps(failed_receipt)
  end

  test "failure and cancellation retain captured provenance" do
    failed = begin_turn("failed-browser", "Fail with provenance.")
    assert {:ok, failed_turn} = Conversations.fail_turn(failed.turn, {:provider_error, "private"})
    assert {:ok, failed_receipt} = Conversations.get_turn_receipt(failed_turn)
    assert failed_receipt.status == "failed"
    assert failed_receipt.persona_digest == failed.context.persona_digest

    assert [%ProviderStep{status: "failed", error_code: "provider_error"}] =
             Conversations.list_provider_steps(failed_receipt)

    cancelled = begin_turn("cancelled-browser", "Cancel with provenance.")
    assert {:ok, cancelled_turn} = Conversations.cancel_turn(cancelled.turn)
    assert {:ok, cancelled_receipt} = Conversations.get_turn_receipt(cancelled_turn)
    assert cancelled_receipt.status == "cancelled"

    assert [%ProviderStep{status: "cancelled", error_code: "cancelled"}] =
             Conversations.list_provider_steps(cancelled_receipt)
  end

  test "startup recovery marks partial receipts and steps interrupted" do
    %{receipt: receipt} = begin_turn("interrupted-browser", "Do not lose provenance.")

    assert :ok = Conversations.recover_interrupted_turns()

    recovered_receipt = Repo.get!(TurnReceipt, receipt.id)
    assert recovered_receipt.status == "interrupted"
    assert recovered_receipt.provider_completed_at

    assert [%ProviderStep{status: "interrupted", error_code: "runtime_restarted"}] =
             Conversations.list_provider_steps(recovered_receipt)
  end

  test "legacy turns remain explicit instead of receiving fabricated provenance" do
    assert {:ok, conversation} = Conversations.ensure_conversation("legacy-browser")
    assert {:ok, records} = Conversations.create_turn(conversation, "Legacy turn.")

    assert {:error, :legacy_turn_without_receipt} =
             Conversations.get_turn_receipt(records.turn)

    assert {:ok, completed_turn} = Conversations.complete_turn(records.turn, "legacy-response")
    assert completed_turn.status == "completed"

    assert {:error, :legacy_turn_without_receipt} =
             Conversations.get_turn_receipt(completed_turn)
  end

  test "the database rejects mid-turn identity mutation" do
    %{receipt: receipt} = begin_turn("immutable-browser", "Keep identity fixed.")

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(
        from(stored_receipt in TurnReceipt, where: stored_receipt.id == ^receipt.id),
        set: [persona_id: "sarah.persona.changed"]
      )
    end
  end

  test "the database rejects role-selection provenance mutation" do
    %{receipt: receipt} = begin_turn("immutable-role-selection", "Keep the selected role fixed.")

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(
        from(stored_receipt in TurnReceipt, where: stored_receipt.id == ^receipt.id),
        set: [role_selection: Map.put(receipt.role_selection, "reason", "silent_sales")]
      )
    end
  end

  test "records an explicit degraded program baseline and protects its receipt" do
    catalog = OpenAgents.ProgramArtifacts.current!()
    degraded = OpenAgents.ProgramArtifacts.capture(catalog, "sarah.unknown.signature.v1")

    %{receipt: receipt} =
      begin_turn(
        "program-degraded-browser",
        "Use the deterministic baseline.",
        "model-v1",
        program_snapshot: degraded
      )

    assert receipt.program_artifact_id == nil
    assert receipt.program_artifact_digest == nil
    assert receipt.program_artifact_receipt["degraded"]
    assert receipt.program_artifact_receipt["reason"] =~ "deterministic_baseline"

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(
        from(stored_receipt in TurnReceipt, where: stored_receipt.id == ^receipt.id),
        set: [
          program_artifact_receipt: Map.put(receipt.program_artifact_receipt, "degraded", false)
        ]
      )
    end
  end

  test "the database keeps the captured profile-memory snapshot immutable" do
    snapshot_ref = "profile-memory-snapshot:v1:#{Ecto.UUID.generate()}"

    %{receipt: receipt} =
      begin_turn("immutable-profile-snapshot", "Keep memory fixed.", "model-v1",
        profile_memory_snapshot_ref: snapshot_ref
      )

    assert receipt.profile_memory_snapshot_ref == snapshot_ref

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(
        from(stored_receipt in TurnReceipt, where: stored_receipt.id == ^receipt.id),
        set: [profile_memory_snapshot_ref: "profile-memory-snapshot:v1:#{Ecto.UUID.generate()}"]
      )
    end
  end

  test "the database rejects terminal memory evidence mutation" do
    %{receipt: receipt, turn: turn} = begin_turn("terminal-evidence-browser", "Freeze evidence.")

    assert {:ok, _completed_turn} =
             Conversations.complete_turn(turn, "terminal-evidence-response")

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(
        from(stored_receipt in TurnReceipt, where: stored_receipt.id == ^receipt.id),
        set: [
          used_memory_evidence: %{
            "schema" => "sarah.memory_evidence_usage.v1",
            "items" => [
              %{
                "source_ref" => "message:#{Ecto.UUID.generate()}",
                "classification" => "applicable"
              }
            ]
          }
        ]
      )
    end
  end

  test "a model configuration change affects only later turns" do
    original_model = Application.fetch_env!(:openagents, :openai_model)
    Application.put_env(:openagents, :test_provider_observer, self())

    on_exit(fn ->
      Application.put_env(:openagents, :openai_model, original_model)
      Application.delete_env(:openagents, :test_provider_observer)
    end)

    first = start_observed_turn("config-browser-one")
    assert_receive {:provider_request, first_task, first_request}
    assert first_request.model_id == original_model

    Application.put_env(:openagents, :openai_model, "model-after-cutover")
    first_pid = first.pid
    first_monitor = Process.monitor(first_pid)
    send(first_task, :continue_provider)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :normal}

    assert {:ok, first_receipt} =
             first.turn_id |> Conversations.get_turn!() |> Conversations.get_turn_receipt()

    assert first_receipt.model_id == original_model
    assert first_receipt.tool_catalog_digest == OpenAgents.Tools.Registry.current!().digest

    second = start_observed_turn("config-browser-two")
    assert_receive {:provider_request, second_task, second_request}
    assert second_request.model_id == "model-after-cutover"
    second_pid = second.pid
    second_monitor = Process.monitor(second_pid)
    send(second_task, :continue_provider)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_pid, :normal}
  end

  defp begin_turn(browser_key, content, model_id \\ "model-v1", options \\ []) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, content)
    context = Composer.compose!()
    messages = Conversations.provider_messages(conversation.id)
    request = %Request{model_id: model_id, instructions: context.instructions, input: messages}

    assert {:ok, inference} =
             Conversations.begin_inference(
               records.turn,
               context,
               request,
               "test.provider",
               options
             )

    Map.merge(inference, %{context: context, request: request})
  end

  defp start_observed_turn(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, "[observe-request]")
    assert {:ok, pid} = Turns.start(records.turn.id)
    %{pid: pid, turn_id: records.turn.id}
  end
end
