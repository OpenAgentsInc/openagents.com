defmodule OpenAgents.Tools.MemoryForget do
  @moduledoc "Forgets explicit record, category, or browser-scope selections idempotently."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Memory.Consent
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Tools.{ExecutionResult, MemoryContext, MemoryContract}

  @categories ~w(name role project preference constraint other)
  @record_categories ["" | @categories]

  @impl true
  def specification do
    MemoryContract.tool(
      __MODULE__,
      "memory_forget",
      "Forgets stored profile memories when the current user message explicitly " <>
        "authorizes it. Mode all (with empty record_id, category, claim, and " <>
        "expected_generation 0) forgets everything without listing first; mode " <>
        "category clears one category; mode record needs the exact record_id, " <>
        "stored claim wording, and expected_generation. Record mode may repeat " <>
        "the selected record category; the record ID and generation remain the " <>
        "authority fence",
      input_schema(),
      output_schema(),
      :reversible_write,
      "memory.write"
    )
  end

  @impl true
  def execute(arguments, context) do
    with {:ok, selector, consent_target} <- selector(arguments),
         {:ok, owner, message, _snapshot} <- MemoryContext.resolve(context),
         {:ok, _consent} <-
           Consent.forget(
             message.content,
             selector["mode"],
             consent_target,
             context.memory_consent
           ),
         {:ok, forgotten} <- ProfileMemory.forget_active(owner, selector) do
      receipt =
        MemoryContract.receipt("forget", forgotten.disposition, message.id, forgotten.records)

      displayed = Enum.take(forgotten.records, 10)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.memory_forget_result.v1",
           "scope" => "this_browser",
           "status" => "succeeded",
           "affected_count" => length(forgotten.records),
           "forgotten" => Enum.map(displayed, &MemoryContract.memory_output/1),
           "truncated" => length(forgotten.records) > length(displayed),
           "receipt" => receipt
         },
         target_receipt_refs: ["message:#{message.id}"]
       }}
    end
  end

  defp selector(%{
         "mode" => "record",
         "record_id" => record_id,
         "category" => category,
         "claim" => claim,
         "expected_generation" => expected_generation
       })
       when is_binary(record_id) and category in @record_categories and is_binary(claim) and
              is_integer(expected_generation) and expected_generation > 0 do
    with {:ok, parsed_id} <- Ecto.UUID.cast(record_id),
         true <- byte_size(claim) in 1..500 do
      {:ok,
       %{
         "mode" => "record",
         "record_id" => parsed_id,
         "expected_generation" => expected_generation
       }, claim}
    else
      _invalid -> {:error, :invalid_forget_selector}
    end
  end

  defp selector(%{
         "mode" => "category",
         "record_id" => "",
         "category" => category,
         "claim" => "",
         "expected_generation" => 0
       })
       when category in @categories,
       do: {:ok, %{"mode" => "category", "category" => category}, category}

  defp selector(%{
         "mode" => "all",
         "record_id" => "",
         "category" => "",
         "claim" => "",
         "expected_generation" => 0
       }),
       do: {:ok, %{"mode" => "all"}, "all"}

  defp selector(_arguments), do: {:error, :invalid_forget_selector}

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => MemoryContract.string(16),
        "record_id" => MemoryContract.string(64),
        "category" => MemoryContract.string(32),
        "claim" => MemoryContract.string(500),
        "expected_generation" => %{"type" => "integer"}
      },
      "required" => ["mode", "record_id", "category", "claim", "expected_generation"],
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
        "affected_count" => %{"type" => "integer"},
        "forgotten" => %{
          "type" => "array",
          "maxItems" => 10,
          "items" => MemoryContract.memory_schema()
        },
        "truncated" => %{"type" => "boolean"},
        "receipt" => MemoryContract.receipt_schema()
      },
      "required" => [
        "schema",
        "scope",
        "status",
        "affected_count",
        "forgotten",
        "truncated",
        "receipt"
      ],
      "additionalProperties" => false
    }
  end
end
