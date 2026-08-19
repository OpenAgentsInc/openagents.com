defmodule OpenAgents.Memory.Evidence do
  @moduledoc "Host-validated historical evidence derived from one frozen recall source."

  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Memory.{LexicalRecall, RecallSnapshot}

  @classifications ~w(applicable weak stale conflicting irrelevant)
  @dispositions [:direct, :weak, :irrelevant]
  @maximum_claim_bytes 800
  @maximum_relevance_bytes 500
  @maximum_related_refs 8
  @stale_after_days 365

  @enforce_keys [
    :source_ref,
    :source_scope,
    :observed_at,
    :recalled_at,
    :claim,
    :relevance,
    :classification,
    :corroborates,
    :conflicts_with
  ]
  defstruct @enforce_keys

  @type classification :: :applicable | :weak | :stale | :conflicting | :irrelevant
  @type t :: %__MODULE__{
          source_ref: String.t(),
          source_scope: map(),
          observed_at: DateTime.t(),
          recalled_at: DateTime.t(),
          claim: String.t(),
          relevance: String.t(),
          classification: classification(),
          corroborates: [String.t()],
          conflicts_with: [String.t()]
        }

  @spec build(Conversation.t(), RecallSnapshot.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def build(conversation, snapshot, source_ref, options \\ [])

  def build(
        %Conversation{id: conversation_id} = conversation,
        %RecallSnapshot{conversation_id: conversation_id} = snapshot,
        source_ref,
        options
      ) do
    disposition = Keyword.get(options, :disposition, :direct)
    relevance = Keyword.get(options, :relevance, "Exact source selected for historical context.")
    corroborates = Keyword.get(options, :corroborates, [])
    conflicts_with = Keyword.get(options, :conflicts_with, [])
    recalled_at = Keyword.get(options, :recalled_at, DateTime.utc_now())

    with true <- disposition in @dispositions,
         :ok <- validate_relevance(relevance),
         :ok <- validate_recalled_at(recalled_at),
         {:ok, source} <- exact_source(conversation, snapshot, source_ref),
         {:ok, corroborates} <- validate_related(conversation, snapshot, corroborates),
         {:ok, conflicts_with} <- validate_related(conversation, snapshot, conflicts_with) do
      classification =
        classify(disposition, source.observed_at, recalled_at, conflicts_with)

      {:ok,
       %__MODULE__{
         source_ref: source.source_ref,
         source_scope: %{
           "kind" => "browser_conversation",
           "ref" => "conversation:#{conversation_id}",
           "snapshot_ref" => RecallSnapshot.ref(snapshot)
         },
         observed_at: source.observed_at,
         recalled_at: recalled_at,
         claim: bounded_claim(source.content),
         relevance: relevance,
         classification: classification,
         corroborates: corroborates,
         conflicts_with: conflicts_with
       }}
    else
      false -> {:error, :invalid_evidence_disposition}
      {:error, reason} -> {:error, reason}
    end
  end

  def build(%Conversation{}, %RecallSnapshot{}, _source_ref, _options),
    do: {:error, :scope_refused}

  @spec to_output(t()) :: map()
  def to_output(%__MODULE__{} = evidence) do
    %{
      "schema" => "sarah.memory_evidence.v1",
      "source_ref" => evidence.source_ref,
      "source_scope" => evidence.source_scope,
      "observed_at" => DateTime.to_iso8601(evidence.observed_at),
      "recalled_at" => DateTime.to_iso8601(evidence.recalled_at),
      "claim" => evidence.claim,
      "relevance" => evidence.relevance,
      "classification" => Atom.to_string(evidence.classification),
      "corroborates" => evidence.corroborates,
      "conflicts_with" => evidence.conflicts_with
    }
  end

  @spec usage_item(t()) :: map()
  def usage_item(%__MODULE__{} = evidence) do
    %{
      "source_ref" => evidence.source_ref,
      "classification" => Atom.to_string(evidence.classification)
    }
  end

  @spec normalize_usage_items(term()) :: {:ok, [map()]} | {:error, atom()}
  def normalize_usage_items(items) when is_list(items) and length(items) <= 20 do
    if Enum.all?(items, &valid_usage_item?/1) do
      {:ok, Enum.uniq_by(items, &{&1["source_ref"], &1["classification"]})}
    else
      {:error, :invalid_memory_evidence_usage}
    end
  end

  def normalize_usage_items(_items), do: {:error, :invalid_memory_evidence_usage}

  def valid_usage_ledger?(%{
        "schema" => "sarah.memory_evidence_usage.v1",
        "items" => items
      }) do
    match?({:ok, ^items}, normalize_usage_items(items)) and
      byte_size(Jason.encode!(items)) <= 4_096
  end

  def valid_usage_ledger?(_ledger), do: false

  defp exact_source(conversation, snapshot, source_ref) do
    case LexicalRecall.read(conversation, snapshot, source_ref, before: 0, after: 0) do
      {:ok, %{messages: [source]}} -> {:ok, source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_related(_conversation, _snapshot, refs)
       when not is_list(refs) or length(refs) > @maximum_related_refs,
       do: {:error, :invalid_evidence_refs}

  defp validate_related(conversation, snapshot, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, validated} ->
      case exact_source(conversation, snapshot, ref) do
        {:ok, _source} -> {:cont, {:ok, [ref | validated]}}
        {:error, _reason} -> {:halt, {:error, :invalid_evidence_refs}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, validated |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp classify(_disposition, _observed_at, _recalled_at, [_conflict | _rest]),
    do: :conflicting

  defp classify(:irrelevant, _observed_at, _recalled_at, []), do: :irrelevant

  defp classify(disposition, observed_at, recalled_at, []) do
    if DateTime.diff(recalled_at, observed_at, :day) > @stale_after_days,
      do: :stale,
      else: classify_current(disposition)
  end

  defp classify_current(:weak), do: :weak
  defp classify_current(:direct), do: :applicable

  defp validate_relevance(relevance)
       when is_binary(relevance) and byte_size(relevance) in 1..@maximum_relevance_bytes,
       do: :ok

  defp validate_relevance(_relevance), do: {:error, :invalid_evidence_relevance}

  defp validate_recalled_at(%DateTime{}), do: :ok
  defp validate_recalled_at(_recalled_at), do: {:error, :invalid_recalled_at}

  defp bounded_claim(content) when byte_size(content) <= @maximum_claim_bytes, do: content

  defp bounded_claim(content) do
    content
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, accumulated ->
      if byte_size(accumulated) + byte_size(grapheme) <= @maximum_claim_bytes,
        do: {:cont, accumulated <> grapheme},
        else: {:halt, accumulated}
    end)
  end

  defp valid_usage_item?(%{
         "source_ref" => "message:" <> message_id,
         "classification" => classification
       }) do
    match?({:ok, _id}, Ecto.UUID.cast(message_id)) and classification in @classifications
  end

  # Durable tool-step sources returned by conversation recall carry the same
  # typed refs the voice evidence window uses (turn-tool-step / voice-tool-step).
  defp valid_usage_item?(%{
         "source_ref" => "turn-tool-step:" <> step_id,
         "classification" => classification
       }) do
    match?({:ok, _id}, Ecto.UUID.cast(step_id)) and classification in @classifications
  end

  defp valid_usage_item?(%{
         "source_ref" => "voice-tool-step:" <> step_id,
         "classification" => classification
       }) do
    match?({:ok, _id}, Ecto.UUID.cast(step_id)) and classification in @classifications
  end

  defp valid_usage_item?(_item), do: false
end
