defmodule OpenAgents.ShadowProgramsTest do
  use OpenAgents.SarahDataCase, async: true
  @moduletag :skip
  alias OpenAgents.{Conversations, ProgramArtifacts, ShadowPrograms}
  alias OpenAgents.Context.Composer
  alias OpenAgents.ProfileMemory.Record
  alias OpenAgents.Providers.Request
  alias OpenAgents.Tools.Registry
  alias OpenAgents.ShadowPrograms.{OpenAI, Run, Schema, Signatures}

  test "all seven versioned signatures have bounded valid baselines" do
    signatures = Signatures.all()

    assert Enum.map(signatures, & &1.id) == [
             "sarah.memory.intent.v1",
             "sarah.memory.candidate.v1",
             "sarah.recall.query.v1",
             "sarah.recall.assessment.v1",
             "sarah.capability.route.v1",
             "sarah.collective.candidate.v1",
             "sarah.response.quality.v1"
           ]

    assert Enum.all?(signatures, &(&1.version == 1))
    assert Enum.all?(signatures, &(Schema.validate(&1.baseline, &1.output_schema) == :ok))
  end

  test "the replay corpus is synthetic and every typed case is valid" do
    corpus =
      "priv/sarah/evals/shadow/corpus.v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert corpus["schema"] == "sarah.shadow_replay_corpus.v1"
    assert corpus["source_kind"] == "synthetic"
    refute corpus["private_production_data"]
    assert length(corpus["cases"]) == 7

    for replay_case <- corpus["cases"] do
      {:ok, signature} = Signatures.fetch(replay_case["signature_id"])
      assert :ok = Schema.validate(replay_case["input"], signature.input_schema)

      assert :ok =
               ShadowPrograms.validate_candidate_output(
                 signature.id,
                 replay_case["output"],
                 replay_case["input"]
               )
    end
  end

  test "runs the admitted memory artifact in shadow and persists only digests/safe shape" do
    receipt = turn_receipt("shadow-success-browser")
    snapshot = ProgramArtifacts.capture("sarah.memory.intent.v1")
    private_text = "Remember that my unreleased project is cobalt-elephant."
    tool_catalog_digest = Registry.current!().digest
    memory_count = Repo.aggregate(Record, :count)

    assert {:ok, run} =
             ShadowPrograms.run(
               receipt.id,
               "sarah.memory.intent.v1",
               %{"current_user_text" => private_text},
               snapshot,
               provider: OpenAgents.ShadowPrograms.TestProvider,
               timeout_ms: 100
             )

    assert run.status == "completed"
    assert run.signature_id == "sarah.memory.intent.v1"
    assert run.artifact_digest == snapshot.artifact.digest
    assert run.provider_response_id == "response-shadow-test"
    assert run.candidate_output == %{"keys" => ["confidence", "intent"], "withheld" => true}
    assert run.comparison["candidate_digest"] == run.candidate_output_digest
    refute inspect(run) =~ private_text
    assert run.usage["total_tokens"] == 14
    assert Registry.current!().digest == tool_catalog_digest
    assert Repo.aggregate(Record, :count) == memory_count

    report = ShadowPrograms.report("sarah.memory.intent.v1")
    assert report["runs"] == 1
    assert report["completed"] == 1
    assert report["input_tokens"] == 10
    assert report["output_tokens"] == 4
    refute report["private_content_included"]
  end

  test "malformed, timed-out, failed, and missing artifact paths persist explicit zero-effect degradation" do
    receipt = turn_receipt("shadow-degrade-browser")
    snapshot = ProgramArtifacts.capture("sarah.memory.intent.v1")
    input = %{"current_user_text" => "hello"}

    cases = [
      {{:ok,
        %{
          output: %{"intent" => "execute_tool", "confidence" => 1.0},
          response_id: "malformed",
          usage: %{}
        }}, "malformed"},
      {{:error, :timed_out}, "timed_out"},
      {{:error, :provider_failed}, "failed"}
    ]

    for {provider_result, expected_status} <- cases do
      Process.put(:shadow_program_result, provider_result)

      assert {:ok, run} =
               ShadowPrograms.run(
                 receipt.id,
                 "sarah.memory.intent.v1",
                 input,
                 snapshot,
                 provider: OpenAgents.ShadowPrograms.TestProvider,
                 timeout_ms: 100
               )

      assert run.status == expected_status
      assert run.comparison["baseline_digest"] == run.candidate_output_digest
    end

    Process.delete(:shadow_program_result)
    catalog = ProgramArtifacts.current!()

    catalog_without_memory = %{
      catalog
      | by_signature: Map.delete(catalog.by_signature, "sarah.memory.intent.v1")
    }

    degraded = ProgramArtifacts.capture(catalog_without_memory, "sarah.memory.intent.v1")

    assert {:ok, run} =
             ShadowPrograms.run(
               receipt.id,
               "sarah.memory.intent.v1",
               input,
               degraded,
               provider: OpenAgents.ShadowPrograms.TestProvider
             )

    assert run.status == "degraded"
    assert run.artifact_id == nil
    assert run.provider_response_id == nil
  end

  test "routing output cannot name a capability absent from the captured catalog" do
    input = %{"request" => "deploy", "captured_capability_ids" => ["memory_list"]}

    assert {:error, :uncaptured_capability_selected} =
             ShadowPrograms.validate_candidate_output(
               "sarah.capability.route.v1",
               %{"selected_capability_id" => "shell_execute", "reason" => "try it"},
               input
             )

    assert :ok =
             ShadowPrograms.validate_candidate_output(
               "sarah.capability.route.v1",
               %{"selected_capability_id" => "memory_list", "reason" => "captured"},
               input
             )
  end

  test "typed input is bounded before any provider call" do
    receipt = turn_receipt("shadow-input-browser")
    snapshot = ProgramArtifacts.capture("sarah.memory.intent.v1")

    assert {:error, {"current_user_text", :string_too_large}} =
             ShadowPrograms.run(
               receipt.id,
               "sarah.memory.intent.v1",
               %{"current_user_text" => String.duplicate("x", 8_001)},
               snapshot,
               provider: OpenAgents.ShadowPrograms.TestProvider
             )
  end

  test "OpenResponses request uses strict structured output without tools or persistence" do
    artifact = ProgramArtifacts.capture("sarah.memory.intent.v1").artifact
    {:ok, signature} = Signatures.fetch("sarah.memory.intent.v1")

    payload =
      OpenAI.request_payload(artifact, signature, %{"current_user_text" => "remember blue"})

    assert payload.model == "gpt-5.6-luna"
    assert payload.stream == false
    assert payload.store == false
    assert payload.text.format.type == "json_schema"
    assert payload.text.format.strict == true
    assert payload.text.format.schema == signature.output_schema
    refute Map.has_key?(payload, :tools)
    refute Map.has_key?(payload, :previous_response_id)
  end

  test "terminal shadow receipts are immutable" do
    receipt = turn_receipt("shadow-immutable-browser")
    snapshot = ProgramArtifacts.capture("sarah.memory.intent.v1")

    assert {:ok, run} =
             ShadowPrograms.run(
               receipt.id,
               "sarah.memory.intent.v1",
               %{"current_user_text" => "hello"},
               snapshot,
               provider: OpenAgents.ShadowPrograms.TestProvider
             )

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(stored in Run, where: stored.id == ^run.id),
        set: [status: "failed"]
      )
    end
  end

  defp turn_receipt(browser_key) do
    {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    {:ok, records} = Conversations.create_turn(conversation, "Run shadow only.")
    context = Composer.compose!()

    request = %Request{
      model_id: "test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    {:ok, inference} =
      Conversations.begin_inference(records.turn, context, request, "test.provider")

    inference.receipt
  end
end
