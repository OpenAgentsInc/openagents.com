defmodule OpenAgents.Observability do
  @moduledoc "Privacy-safe operational events; durable receipts remain authoritative."

  @event [:openagents, :operation]
  @planes ~w(provider tool memory module collective evaluation)
  @operations ~w(respond execute recall write correct forget route consent review publish revoke evaluate reconcile recover)
  @reason_codes ~w(
    admitted_proposal_selected deterministic_baseline_selected
    exact_proposal_unavailable_or_refused no_policy_eligible_module
    unknown_tool incompatible_tool_version module_artifact_missing
    module_executor_unavailable module_integrity_mismatch scope_refused
    authority_refused surface_not_admitted surface_unknown
    module_approval_required target_receipt_required timeout cancelled
    output_too_large invalid_tool_output invalid_arguments_json
    arguments_must_be_an_object arguments_too_large memory_consent_required
    memory_consent_mismatch memory_policy_refused not_found lexical_unavailable
    other
  )
  @statuses ~w(started succeeded failed refused cancelled unavailable degraded selected recalled corrected forgotten consented reviewed published revoked blocked)
  @surfaces OpenAgents.Modules.SurfacePolicy.surfaces()
  @metadata_keys ~w(plane operation status surface provider_id model_id module_id module_version artifact_id reason_code)a
  @private_fragments ~w(content message prompt secret token memory payload arguments result instructions email name)
  @identifier ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}\z/

  def event_name, do: @event
  def planes, do: @planes
  def statuses, do: @statuses

  @spec emit(map(), map()) :: :ok | {:error, atom()}
  def emit(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    with :ok <- validate_measurements(measurements),
         :ok <- validate_metadata(metadata) do
      :telemetry.execute(@event, Map.put_new(measurements, :count, 1), metadata)
      :ok
    end
  end

  def emit(_measurements, _metadata), do: {:error, :telemetry_event_invalid}

  def tool_outcome(outcome, surface, duration_ms) do
    emit(%{duration_ms: max(duration_ms, 0)}, %{
      plane: "tool",
      operation: "execute",
      status: outcome["status"],
      surface: surface,
      module_id: get_in(outcome, ["module_ref", "module_id"]),
      module_version: get_in(outcome, ["module_ref", "version"]),
      reason_code: normalize_reason(get_in(outcome, ["error", "code"]))
    })
  end

  def module_route(decision) do
    emit(%{}, %{
      plane: "module",
      operation: "route",
      status: decision.status,
      surface: decision.surface,
      module_id: get_in(decision.selected || %{}, ["module_id"]),
      module_version: get_in(decision.selected || %{}, ["version"]),
      reason_code: normalize_reason(decision.reason)
    })
  end

  @spec validate_metadata(map()) :: :ok | {:error, atom()}
  def validate_metadata(metadata) do
    keys = Map.keys(metadata)

    cond do
      Enum.any?(keys, &(&1 not in @metadata_keys)) ->
        {:error, :telemetry_metadata_key_refused}

      Enum.any?(keys, &private_key?/1) ->
        {:error, :telemetry_private_metadata_refused}

      metadata[:plane] not in @planes ->
        {:error, :telemetry_plane_invalid}

      metadata[:operation] not in @operations ->
        {:error, :telemetry_operation_invalid}

      metadata[:status] not in @statuses ->
        {:error, :telemetry_status_invalid}

      Map.has_key?(metadata, :reason_code) and not is_nil(metadata.reason_code) and
          metadata.reason_code not in @reason_codes ->
        {:error, :telemetry_reason_code_invalid}

      Map.has_key?(metadata, :surface) and metadata.surface not in @surfaces ->
        {:error, :telemetry_surface_invalid}

      Enum.any?(metadata, fn {key, value} ->
        key not in [:module_version] and not optional_identifier?(value)
      end) ->
        {:error, :telemetry_identifier_invalid}

      Map.has_key?(metadata, :module_version) and
          not (is_nil(metadata.module_version) or
                   (is_integer(metadata.module_version) and metadata.module_version in 1..10_000)) ->
        {:error, :telemetry_identifier_invalid}

      true ->
        :ok
    end
  end

  defp validate_measurements(measurements) do
    if Enum.all?(measurements, fn
         {key, value} when key in [:count, :duration_ms, :value] ->
           is_number(value) and value >= 0 and value <= 86_400_000

         _other ->
           false
       end),
       do: :ok,
       else: {:error, :telemetry_measurement_invalid}
  end

  defp private_key?(key) do
    key
    |> Atom.to_string()
    |> then(fn text -> Enum.any?(@private_fragments, &String.contains?(text, &1)) end)
  end

  defp optional_identifier?(nil), do: true
  defp optional_identifier?(value), do: valid_identifier?(value)
  defp valid_identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)
  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when reason in @reason_codes, do: reason
  defp normalize_reason(_reason), do: "other"
end
