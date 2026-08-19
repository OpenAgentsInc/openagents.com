defmodule OpenAgents.Tools.MemoryCorrect do
  @moduledoc "Supersedes one active profile memory with a corrected claim."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Memory.Consent
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Tools.{ExecutionResult, MemoryContext, MemoryContract}

  @impl true
  def specification do
    MemoryContract.tool(
      __MODULE__,
      "memory_correct",
      "Replaces one active profile memory with an updated claim when the user " <>
        "states a changed fact that conflicts with a stored record. Use " <>
        "memory_list to find the record's id and generation, then pass the new " <>
        "claim; the old record is superseded, not duplicated",
      input_schema(),
      output_schema(),
      :reversible_write,
      "memory.write"
    )
  end

  @impl true
  def execute(
        %{
          "record_id" => record_id,
          "expected_generation" => expected_generation,
          "category" => category,
          "claim" => claim
        },
        context
      )
      when is_binary(record_id) and is_integer(expected_generation) and
             expected_generation > 0 and is_binary(category) and is_binary(claim) do
    category = MemoryContract.normalize_category(category)

    with {:ok, owner, message, _snapshot} <- MemoryContext.resolve(context) do
      consent = consent_evidence(message, claim, context.memory_consent)

      case ProfileMemory.correct(owner, record_id, expected_generation, %{
             category: category,
             claim: claim,
             creator: "user_explicit",
             provenance: %{
               "consent_kind" => consent.kind,
               "operation" => "correct",
               "source_ref" => "message:#{message.id}"
             },
             sources: [
               %{
                 source_ref: "message:#{message.id}",
                 kind:
                   if(consent.kind in ["current_message", "conversation_context"],
                     do: "owner_statement",
                     else: "owner_confirmation"
                   )
               }
             ]
           }) do
        {:ok, %{superseded: superseded, replacement: replacement}} ->
          receipt =
            MemoryContract.receipt("correct", "corrected", message.id, [replacement])

          {:ok,
           %ExecutionResult{
             result: %{
               "schema" => "sarah.memory_correct_result.v1",
               "scope" => "this_browser",
               "status" => "succeeded",
               "superseded_record_ref" => MemoryContract.record_ref(superseded),
               "memory" => MemoryContract.memory_output(replacement),
               "receipt" => receipt
             },
             target_receipt_refs: [
               "message:#{message.id}",
               MemoryContract.record_ref(replacement)
             ]
           }}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, _bounded_reason} ->
          {:error, :memory_policy_refused}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_memory_arguments}

  defp consent_evidence(message, claim, context_consent) do
    case Consent.remember(message.content, claim, context_consent) do
      {:ok, consent} -> consent
      {:error, _no_explicit_request} -> %{kind: "conversation_context"}
    end
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "record_id" => MemoryContract.string(64),
        "expected_generation" => %{"type" => "integer", "minimum" => 1},
        "category" =>
          Map.put(
            MemoryContract.string(32),
            "enum",
            OpenAgents.ProfileMemory.Record.categories()
          ),
        "claim" => MemoryContract.string(500)
      },
      "required" => ["record_id", "expected_generation", "category", "claim"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => MemoryContract.string(64),
        "scope" => MemoryContract.string(32),
        "status" => MemoryContract.string(16),
        "superseded_record_ref" => MemoryContract.string(128),
        "memory" => MemoryContract.memory_schema(),
        "receipt" => MemoryContract.receipt_schema()
      },
      "required" => ["schema", "scope", "status", "superseded_record_ref", "memory", "receipt"],
      "additionalProperties" => false
    }
  end
end
