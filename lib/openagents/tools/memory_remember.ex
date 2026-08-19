defmodule OpenAgents.Tools.MemoryRemember do
  @moduledoc "Stores durable profile memories sourced from the current user message."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Memory.Consent
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Tools.{ExecutionResult, MemoryContext, MemoryContract}

  @maximum_memories 8

  @impl true
  def specification do
    MemoryContract.tool(
      __MODULE__,
      "memory_remember",
      "Stores lasting profile facts about the user (name, role, project, preference, " <>
        "constraint, or other). Call this automatically whenever the user shares durable " <>
        "information; no explicit request to remember is needed. Batch every fact from " <>
        "the current message into a single call",
      input_schema(),
      output_schema(),
      :reversible_write,
      "memory.write",
      maximum_input_bytes: 8_192
    )
  end

  @impl true
  def execute(%{"memories" => memories}, context)
      when is_list(memories) and memories != [] and length(memories) <= @maximum_memories do
    with {:ok, owner, message, _snapshot} <- MemoryContext.resolve(context) do
      outcomes =
        Enum.map(memories, &store(owner, message, context.memory_consent, &1))

      stored_records =
        for {:ok, %{record: record}} <- outcomes, do: record

      if stored_records == [] do
        {:error, first_error(outcomes)}
      else
        disposition =
          if Enum.any?(outcomes, &match?({:ok, %{disposition: "stored"}}, &1)),
            do: "stored",
            else: "already_active"

        receipt = MemoryContract.receipt("remember", disposition, message.id, stored_records)

        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "sarah.memory_remember_result.v1",
             "scope" => "this_browser",
             "status" => "succeeded",
             "results" => Enum.map(outcomes, &entry/1),
             "receipt" => receipt
           },
           target_receipt_refs: [
             "message:#{message.id}" | Enum.map(stored_records, &MemoryContract.record_ref/1)
           ]
         }}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_memory_arguments}

  defp store(owner, message, context_consent, %{"category" => category, "claim" => claim})
       when is_binary(category) and is_binary(claim) do
    category = MemoryContract.normalize_category(category)
    consent = consent_evidence(message, claim, context_consent)

    case ProfileMemory.remember_explicit(owner, %{
           category: category,
           claim: claim,
           creator: "user_explicit",
           provenance: %{
             "consent_kind" => consent.kind,
             "operation" => "remember",
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
      {:ok, remembered} ->
        {:ok, Map.put(remembered, :category, category)}

      {:error, reason} when is_atom(reason) ->
        {:error, category, reason}

      {:error, _bounded_reason} ->
        {:error, category, :memory_policy_refused}
    end
  end

  defp store(_owner, _message, _consent, _invalid_item),
    do: {:error, "other", :invalid_memory_arguments}

  defp entry({:ok, %{disposition: disposition, record: record, category: category}}) do
    %{
      "disposition" => disposition,
      "category" => category,
      "memory" => MemoryContract.memory_output(record)
    }
  end

  defp entry({:error, category, reason}) do
    %{
      "disposition" => "refused",
      "category" => category,
      "code" => Atom.to_string(reason)
    }
  end

  defp first_error(outcomes) do
    Enum.find_value(outcomes, :memory_policy_refused, fn
      {:error, _category, reason} -> reason
      _stored -> nil
    end)
  end

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
        "memories" => %{
          "type" => "array",
          "maxItems" => @maximum_memories,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "category" =>
                Map.put(
                  MemoryContract.string(32),
                  "enum",
                  OpenAgents.ProfileMemory.Record.categories()
                ),
              "claim" => MemoryContract.string(500)
            },
            "required" => ["category", "claim"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["memories"],
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
        "results" => %{
          "type" => "array",
          "maxItems" => @maximum_memories,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "disposition" => MemoryContract.string(32),
              "category" => MemoryContract.string(32),
              "code" => MemoryContract.string(64),
              "memory" => MemoryContract.memory_schema()
            },
            "required" => ["disposition", "category"],
            "additionalProperties" => false
          }
        },
        "receipt" => MemoryContract.receipt_schema()
      },
      "required" => ["schema", "scope", "status", "results", "receipt"],
      "additionalProperties" => false
    }
  end
end
