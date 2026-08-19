defmodule OpenAgents.ProgramArtifacts.Reader do
  @moduledoc """
  Pure validator and canonical reader for DS-Effect-style program artifacts.

  The reader returns data. It has no executor, tool, registry, persona,
  persistence, provider, approval, or promotion callback.
  """

  alias OpenAgents.ProgramArtifacts.Artifact
  alias OpenAgents.Provenance.Canonical

  @schema "sarah.model_program_artifact.v1"
  @runtime_compatibility 1
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @allowed_output_kinds ~w(proposal selection score)
  @allowed_activation_statuses ~w(shadow active)
  @maximum_document_bytes 65_536
  @maximum_prompt_blocks 32

  @required_top_level ~w(
    schema artifact_id artifact_digest signature compiler model decoding
    compatibility prompt_ir parameters datasets optimizer evaluator metrics
    provenance approval predecessor activation_status
  )

  @spec read(String.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def read(contents)
      when is_binary(contents) and byte_size(contents) <= @maximum_document_bytes do
    read_document(contents, :admitted)
  end

  def read(_contents), do: {:error, :artifact_document_too_large_or_invalid}

  @spec read_candidate(String.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def read_candidate(contents)
      when is_binary(contents) and byte_size(contents) <= @maximum_document_bytes do
    read_document(contents, :candidate)
  end

  def read_candidate(_contents), do: {:error, :artifact_document_too_large_or_invalid}

  defp read_document(contents, mode) do
    with {:ok, document} <- decode(contents),
         :ok <- validate(document, mode),
         digest <- digest(document),
         :ok <- digest_matches(document["artifact_digest"], digest) do
      {:ok,
       %Artifact{
         id: document["artifact_id"],
         signature_id: document["signature"]["id"],
         digest: digest,
         activation_status: document["activation_status"],
         predecessor: document["predecessor"],
         document: document
       }}
    end
  end

  @spec digest(map()) :: String.t()
  def digest(document) when is_map(document) do
    document
    |> Map.delete("artifact_digest")
    |> Canonical.digest!()
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _invalid -> {:error, :artifact_json_invalid}
    end
  end

  defp validate(document, mode) do
    with :ok <- validate_top_level(document),
         :ok <- validate_signature(document["signature"]),
         :ok <- validate_compiler(document["compiler"]),
         :ok <- validate_model(document["model"], document["decoding"]),
         :ok <- validate_compatibility(document["compatibility"]),
         :ok <- validate_prompt(document["prompt_ir"], document["parameters"]),
         :ok <- validate_datasets(document["datasets"]),
         :ok <- validate_optimizer(document["optimizer"]),
         :ok <- validate_evaluation(document["evaluator"], document["metrics"]),
         :ok <- validate_provenance(document["provenance"]),
         :ok <- validate_approval(document["approval"], mode),
         :ok <- validate_activation(document["activation_status"], mode) do
      :ok
    end
  end

  defp validate_top_level(document) do
    cond do
      document["schema"] != @schema ->
        {:error, :incompatible_artifact_schema}

      Enum.any?(@required_top_level, &(not Map.has_key?(document, &1))) ->
        {:error, :artifact_field_missing}

      not non_empty?(document["artifact_id"]) ->
        {:error, :artifact_id_invalid}

      not valid_digest?(document["artifact_digest"]) ->
        {:error, :artifact_digest_invalid}

      document["predecessor"] != nil and not non_empty?(document["predecessor"]) ->
        {:error, :predecessor_invalid}

      true ->
        :ok
    end
  end

  defp validate_signature(%{
         "id" => id,
         "version" => version,
         "input_schema" => input_schema,
         "output_schema" => output_schema,
         "output_kind" => output_kind
       }) do
    cond do
      not non_empty?(id) or not positive_integer?(version) ->
        {:error, :program_signature_invalid}

      not bounded_schema?(input_schema) or not bounded_schema?(output_schema) ->
        {:error, :program_signature_invalid}

      output_kind not in @allowed_output_kinds ->
        {:error, :program_output_kind_forbidden}

      authority_fields?(output_schema) ->
        {:error, :program_output_authority_forbidden}

      true ->
        :ok
    end
  end

  defp validate_signature(_signature), do: {:error, :program_signature_invalid}

  defp validate_compiler(%{"id" => id, "version" => version, "source_digest" => digest}) do
    if non_empty?(id) and non_empty?(version) and valid_digest?(digest),
      do: :ok,
      else: {:error, :compiler_identity_invalid}
  end

  defp validate_compiler(_compiler), do: {:error, :compiler_identity_invalid}

  defp validate_model(%{"provider" => provider, "model" => model}, decoding)
       when is_map(decoding) do
    if non_empty?(provider) and non_empty?(model) and map_size(decoding) > 0,
      do: :ok,
      else: {:error, :model_or_decoding_identity_invalid}
  end

  defp validate_model(_model, _decoding), do: {:error, :model_or_decoding_identity_invalid}

  defp validate_compatibility(%{"runtime_min" => minimum, "runtime_max" => maximum}) do
    if positive_integer?(minimum) and positive_integer?(maximum) and
         minimum <= @runtime_compatibility and maximum >= @runtime_compatibility,
       do: :ok,
       else: {:error, :artifact_runtime_incompatible}
  end

  defp validate_compatibility(_compatibility), do: {:error, :artifact_runtime_incompatible}

  defp validate_prompt(%{"version" => version, "blocks" => blocks}, parameters)
       when is_list(blocks) and is_map(parameters) do
    cond do
      not positive_integer?(version) -> {:error, :prompt_ir_invalid}
      blocks == [] or length(blocks) > @maximum_prompt_blocks -> {:error, :prompt_ir_invalid}
      not Enum.all?(blocks, &valid_prompt_block?/1) -> {:error, :prompt_ir_invalid}
      byte_size(Jason.encode!(parameters)) > 16_384 -> {:error, :program_parameters_too_large}
      true -> :ok
    end
  end

  defp validate_prompt(_prompt, _parameters), do: {:error, :prompt_ir_invalid}

  defp validate_datasets(%{"train" => train, "validation" => validation, "holdout" => holdout}) do
    datasets = [train, validation, holdout]

    cond do
      not Enum.all?(datasets, &valid_dataset?/1) ->
        {:error, :dataset_manifest_invalid}

      length(Enum.uniq(Enum.map(datasets, & &1["id"]))) != 3 ->
        {:error, :true_holdout_not_independent}

      length(Enum.uniq(Enum.map(datasets, & &1["content_digest"]))) != 3 ->
        {:error, :true_holdout_not_independent}

      holdout["purpose"] != "true_holdout" ->
        {:error, :true_holdout_missing}

      true ->
        :ok
    end
  end

  defp validate_datasets(_datasets), do: {:error, :true_holdout_missing}

  defp validate_optimizer(%{"id" => id, "version" => version, "budget" => budget})
       when is_map(budget) do
    if non_empty?(id) and non_empty?(version) and valid_budget?(budget),
      do: :ok,
      else: {:error, :optimizer_budget_invalid}
  end

  defp validate_optimizer(_optimizer), do: {:error, :optimizer_budget_invalid}

  defp validate_evaluation(
         %{"id" => id, "version" => version, "digest" => digest},
         %{"baseline" => baseline, "candidate" => candidate, "uncertainty" => uncertainty}
       )
       when is_map(baseline) and is_map(candidate) and is_map(uncertainty) do
    if non_empty?(id) and non_empty?(version) and valid_digest?(digest) and
         map_size(baseline) > 0 and map_size(candidate) > 0 and map_size(uncertainty) > 0,
       do: :ok,
       else: {:error, :evaluation_evidence_invalid}
  end

  defp validate_evaluation(_evaluator, _metrics), do: {:error, :evaluation_evidence_invalid}

  defp validate_provenance(%{
         "source_revision" => revision,
         "compiled_at" => compiled_at,
         "compiled_by" => compiled_by,
         "receipt" => receipt
       }) do
    if non_empty?(revision) and valid_datetime?(compiled_at) and non_empty?(compiled_by) and
         is_map(receipt) and map_size(receipt) > 0,
       do: :ok,
       else: {:error, :artifact_provenance_invalid}
  end

  defp validate_provenance(_provenance), do: {:error, :artifact_provenance_invalid}

  defp validate_approval(
         %{
           "status" => "approved",
           "approved_by" => approved_by,
           "approved_at" => approved_at,
           "receipt" => receipt
         },
         :admitted
       ) do
    if non_empty?(approved_by) and valid_datetime?(approved_at) and is_map(receipt) and
         map_size(receipt) > 0,
       do: :ok,
       else: {:error, :artifact_approval_invalid}
  end

  defp validate_approval(%{"status" => "pending", "receipt" => receipt}, :candidate)
       when is_map(receipt),
       do: :ok

  defp validate_approval(_approval, _mode), do: {:error, :artifact_unapproved}

  defp validate_activation(status, :admitted) when status in @allowed_activation_statuses,
    do: :ok

  defp validate_activation("candidate", :candidate), do: :ok
  defp validate_activation(_status, _mode), do: {:error, :artifact_activation_status_invalid}

  defp valid_prompt_block?(%{"id" => id, "kind" => kind, "content" => content}),
    do:
      non_empty?(id) and kind in ~w(instruction examples output_contract) and non_empty?(content)

  defp valid_prompt_block?(_block), do: false

  defp valid_dataset?(%{
         "id" => id,
         "revision" => revision,
         "content_digest" => digest,
         "purpose" => purpose,
         "source_kind" => source_kind,
         "consent_receipt" => consent_receipt
       }) do
    source_valid? =
      (source_kind == "synthetic" and is_nil(consent_receipt)) or
        (source_kind == "consented_fixture" and is_map(consent_receipt) and
           map_size(consent_receipt) > 0)

    non_empty?(id) and non_empty?(revision) and valid_digest?(digest) and
      purpose in ~w(train validation true_holdout) and source_valid?
  end

  defp valid_dataset?(_dataset), do: false

  defp valid_budget?(%{
         "max_trials" => trials,
         "max_model_calls" => calls,
         "max_cost_usd" => cost
       }),
       do: positive_integer?(trials) and positive_integer?(calls) and is_number(cost) and cost > 0

  defp valid_budget?(_budget), do: false

  defp bounded_schema?(schema) when is_map(schema),
    do:
      schema["type"] == "object" and is_map(schema["properties"]) and is_list(schema["required"])

  defp bounded_schema?(_schema), do: false

  defp authority_fields?(output_schema) do
    forbidden =
      MapSet.new(~w(execute tool_call add_tool policy_update persona_update promote activate))

    output_schema["properties"]
    |> Map.keys()
    |> Enum.any?(&MapSet.member?(forbidden, &1))
  end

  defp digest_matches(digest, digest), do: :ok
  defp digest_matches(_stored, _calculated), do: {:error, :artifact_digest_mismatch}
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_regex, value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_datetime?(value) when is_binary(value) do
    match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp valid_datetime?(_value), do: false
end
