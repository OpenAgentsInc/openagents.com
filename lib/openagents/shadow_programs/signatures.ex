defmodule OpenAgents.ShadowPrograms.Signatures do
  @moduledoc "Versioned signature catalog for Sarah shadow decisions."

  alias OpenAgents.ShadowPrograms.Signature

  @definitions [
    {"sarah.memory.intent.v1", ~w(current_user_text),
     %{
       "intent" => %{"enum" => ~w(remember forget list none)},
       "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
     }, %{"intent" => "none", "confidence" => 1.0}},
    {"sarah.memory.candidate.v1", ~w(authorized_statement source_ref),
     %{
       "candidate" => %{"type" => ["string", "null"], "maxLength" => 500},
       "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
     }, %{"candidate" => nil, "confidence" => 1.0}},
    {"sarah.recall.query.v1", ~w(current_user_text),
     %{
       "needed" => %{"type" => "boolean"},
       "query" => %{"type" => ["string", "null"], "maxLength" => 500}
     }, %{"needed" => false, "query" => nil}},
    {"sarah.recall.assessment.v1", ~w(question evidence_excerpt),
     %{
       "classification" => %{"enum" => ~w(applicable weak stale conflicting irrelevant)},
       "reason" => %{"type" => "string", "maxLength" => 500}
     }, %{"classification" => "irrelevant", "reason" => "deterministic baseline"}},
    {"sarah.capability.route.v1", ~w(request captured_capability_ids),
     %{
       "selected_capability_id" => %{"type" => ["string", "null"], "maxLength" => 160},
       "reason" => %{"type" => "string", "maxLength" => 500}
     }, %{"selected_capability_id" => nil, "reason" => "deterministic baseline"}},
    {"sarah.collective.candidate.v1", ~w(consented_fixture),
     %{
       "candidate" => %{"type" => ["string", "null"], "maxLength" => 1000},
       "reason" => %{"type" => "string", "maxLength" => 500}
     }, %{"candidate" => nil, "reason" => "deterministic baseline"}},
    {"sarah.response.quality.v1", ~w(response_text),
     %{
       "score" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
       "reason" => %{"type" => "string", "maxLength" => 500}
     }, %{"score" => 0.0, "reason" => "not evaluated"}}
  ]

  def all, do: Enum.map(@definitions, &build/1)

  def fetch(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> {:error, :unknown_shadow_signature}
      signature -> {:ok, signature}
    end
  end

  defp build({id, required_inputs, output_properties, baseline}) do
    input_properties = Map.new(required_inputs, &{&1, input_property(&1)})

    %Signature{
      id: id,
      version: 1,
      input_schema: object_schema(input_properties, required_inputs),
      output_schema: object_schema(output_properties, Map.keys(output_properties)),
      baseline: baseline
    }
  end

  defp input_property("captured_capability_ids"),
    do: %{
      "type" => "array",
      "items" => %{"type" => "string", "maxLength" => 160},
      "maxItems" => 64
    }

  defp input_property(key)
       when key in ~w(current_user_text authorized_statement question evidence_excerpt request consented_fixture response_text),
       do: %{"type" => "string", "maxLength" => 8_000}

  defp input_property("source_ref"), do: %{"type" => "string", "maxLength" => 256}

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.sort(required),
      "additionalProperties" => false
    }
  end
end
