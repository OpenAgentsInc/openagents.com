defmodule OpenAgents.Modules.Artifact do
  @moduledoc "Immutable provider-neutral module contract admitted into one registry snapshot."

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Tools.{Schema, Tool}

  @runtime_version 1
  @states ~w(admitted deprecated disabled revoked)
  @identifier_regex ~r/\A[a-z][a-z0-9_.-]*\z/
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @enforce_keys [
    :schema,
    :module_id,
    :version,
    :kind,
    :state,
    :input_schema,
    :output_schema,
    :side_effect_class,
    :approval_class,
    :executor,
    :capability_scopes,
    :data_scopes,
    :facets,
    :publisher,
    :maintainer,
    :provenance,
    :compatibility,
    :predecessor,
    :deprecation,
    :rollback,
    :attribution_policy,
    :attribution,
    :implementation_digest,
    :artifact_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec from_tool(Tool.t()) :: {:ok, t()} | {:error, term()}
  def from_tool(%Tool{} = tool) do
    with {:ok, implementation_digest, integrity_subject} <-
           implementation_identity(tool.implementation),
         :ok <- validate_metadata(tool.module_metadata),
         :ok <- validate_tool_alignment(tool),
         artifact <- build(tool, implementation_digest, integrity_subject),
         :ok <- validate(artifact) do
      {:ok, artifact}
    end
  end

  @spec from_collective(map()) :: {:ok, t()} | {:error, term()}
  def from_collective(attributes) when is_map(attributes) do
    implementation_digest = attributes.output_digest

    attribution_policy = %{
      "id" => "sarah.collective.attribution.v1",
      "version" => 1,
      "mode" => "opaque_contribution_lineage",
      "required" => true
    }

    attribution_policy =
      Map.put(attribution_policy, "digest", Canonical.digest!(attribution_policy))

    fields = %{
      schema: "sarah.module_artifact.v1",
      module_id: attributes.module_id,
      version: attributes.version,
      kind: "plugin",
      state: "disabled",
      input_schema: attributes.input_schema,
      output_schema: attributes.output_schema,
      side_effect_class: "read_only",
      approval_class: "explicit_operator_approval",
      executor: %{
        id: "sarah.collective.catalog",
        disclosure: "Reviewed collective pattern; no executable implementation is installed",
        implementation: "collective_payload:#{implementation_digest}",
        implementation_digest: implementation_digest,
        configuration: attributes.payload
      },
      capability_scopes: ["collective.pattern.reviewed"],
      data_scopes: ["collective.deidentified"],
      facets: %{
        "cost" => "none_until_executor_admission",
        "quality" => "independently_reviewed",
        "residency" => "host",
        "privacy" => "deidentified",
        "surfaces" => ["text"],
        "approval_enforcement" => "host_receipt"
      },
      publisher: "OpenAgents collective review",
      maintainer: attributes.maintainer,
      provenance: %{
        "source" => "consented_generalized_candidate",
        "admission" => attributes.review_ref,
        "integrity" => %{
          "algorithm" => "sha256",
          "subject" => "collective_generalized_payload",
          "digest" => implementation_digest
        }
      },
      compatibility: %{"runtime_min" => 1, "runtime_max" => 1, "dependencies" => []},
      predecessor: attributes.predecessor,
      deprecation: nil,
      rollback: %{"strategy" => "disable_revoke_and_rebuild_derivatives"},
      attribution_policy: attribution_policy,
      attribution: attributes.attribution,
      implementation_digest: implementation_digest,
      artifact_digest: String.duplicate("0", 64)
    }

    artifact = struct!(__MODULE__, fields)
    artifact = %{artifact | artifact_digest: artifact_digest(artifact)}

    case validate(artifact) do
      :ok -> {:ok, artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_collective(_attributes), do: {:error, :collective_artifact_invalid}

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    fields =
      __MODULE__.__struct__()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__struct__))
      |> Map.new(fn key -> {key, Map.get(map, key) || Map.get(map, Atom.to_string(key))} end)
      |> Map.update(:executor, %{}, fn executor ->
        %{
          id: executor[:id] || executor["id"],
          disclosure: executor[:disclosure] || executor["disclosure"],
          implementation: executor[:implementation] || executor["implementation"],
          implementation_digest:
            executor[:implementation_digest] || executor["implementation_digest"],
          configuration: executor[:configuration] || executor["configuration"]
        }
      end)

    artifact = struct!(__MODULE__, fields)

    case validate(artifact) do
      :ok -> {:ok, artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_map(_map), do: {:error, :module_artifact_invalid}

  @spec executable?(t()) :: boolean()
  def executable?(%__MODULE__{state: state}), do: state in ~w(admitted deprecated)

  @spec verify_implementation(t(), module()) :: :ok | {:error, atom()}
  def verify_implementation(%__MODULE__{} = artifact, module) do
    case implementation_identity(module) do
      {:ok, digest, _subject} when digest == artifact.implementation_digest -> :ok
      {:ok, _digest, _subject} -> {:error, :module_integrity_mismatch}
      {:error, _reason} -> {:error, :module_executor_unavailable}
    end
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = artifact) do
    surface_validation = OpenAgents.Modules.SurfacePolicy.validate_artifact(artifact)

    cond do
      not identifier?(artifact.module_id) ->
        {:error, :module_id_invalid}

      not is_integer(artifact.version) or artifact.version < 1 ->
        {:error, :module_version_invalid}

      artifact.kind not in ~w(tool model_executor agent_executor plugin) ->
        {:error, :module_kind_invalid}

      artifact.state not in @states ->
        {:error, :module_state_invalid}

      not valid_schema?(artifact.input_schema) or not valid_schema?(artifact.output_schema) ->
        {:error, :module_schema_invalid}

      artifact.side_effect_class not in ~w(read_only reversible_write external_effect) ->
        {:error, :module_side_effect_invalid}

      artifact.approval_class not in ~w(host_policy exact_current_user_consent explicit_operator_approval external_confirmation) ->
        {:error, :module_approval_invalid}

      artifact.side_effect_class == "reversible_write" and
          artifact.approval_class != "exact_current_user_consent" ->
        {:error, :module_approval_mismatch}

      not valid_executor?(artifact.executor, artifact.implementation_digest) ->
        {:error, :module_executor_invalid}

      not valid_scopes?(artifact.capability_scopes) ->
        {:error, :module_capability_scope_invalid}

      not valid_scopes?(artifact.data_scopes) ->
        {:error, :module_data_scope_invalid}

      not complete_facets?(artifact.facets) ->
        {:error, :module_facets_incomplete}

      match?({:error, _reason}, surface_validation) ->
        surface_validation

      not non_empty?(artifact.publisher) or not non_empty?(artifact.maintainer) ->
        {:error, :module_ownership_invalid}

      not valid_provenance?(artifact.provenance, artifact.implementation_digest) ->
        {:error, :module_provenance_invalid}

      not valid_compatibility?(artifact.compatibility) ->
        {:error, :module_incompatible}

      not valid_optional_ref?(artifact.predecessor) ->
        {:error, :module_predecessor_invalid}

      not valid_deprecation?(artifact.state, artifact.deprecation) ->
        {:error, :module_deprecation_invalid}

      not is_map(artifact.rollback) or not non_empty?(artifact.rollback["strategy"]) ->
        {:error, :module_rollback_invalid}

      not valid_attribution_policy?(artifact.attribution_policy) ->
        {:error, :module_attribution_policy_invalid}

      artifact.attribution_policy["required"] and artifact.attribution == [] ->
        {:error, :module_attribution_missing}

      not valid_digest?(artifact.implementation_digest) ->
        {:error, :module_implementation_invalid}

      artifact.artifact_digest != artifact_digest(artifact) ->
        {:error, :module_artifact_digest_invalid}

      true ->
        :ok
    end
  end

  @spec artifact_digest(t()) :: String.t()
  def artifact_digest(%__MODULE__{} = artifact) do
    artifact
    |> Map.from_struct()
    |> Map.delete(:artifact_digest)
    |> Canonical.digest!()
  end

  @spec transition(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition(artifact, state, options \\ [])

  def transition(%__MODULE__{} = artifact, state, options) when state in @states do
    transitioned = %{
      artifact
      | state: state,
        predecessor: Keyword.get(options, :predecessor, artifact.predecessor),
        deprecation: Keyword.get(options, :deprecation),
        artifact_digest: String.duplicate("0", 64)
    }

    transitioned = %{transitioned | artifact_digest: artifact_digest(transitioned)}

    case validate(transitioned) do
      :ok -> {:ok, transitioned}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition(%__MODULE__{}, _state, _options), do: {:error, :module_state_invalid}

  defp build(tool, implementation_digest, integrity_subject) do
    metadata = tool.module_metadata

    fields = %{
      schema: "sarah.module_artifact.v1",
      module_id: tool.module_id,
      version: tool.version,
      kind: "tool",
      state: metadata["state"],
      input_schema: tool.input_schema,
      output_schema: tool.output_schema,
      side_effect_class: Atom.to_string(tool.side_effect),
      approval_class: metadata["approval_class"],
      executor:
        Map.merge(tool.executor, %{
          implementation: inspect(tool.implementation),
          implementation_digest: implementation_digest
        }),
      capability_scopes: metadata["capability_scopes"],
      data_scopes: metadata["data_scopes"],
      facets: metadata["facets"],
      publisher: metadata["publisher"],
      maintainer: tool.maintainer,
      provenance:
        Map.put(metadata["provenance"], "integrity", %{
          "algorithm" => "sha256",
          "subject" => integrity_subject,
          "digest" => implementation_digest
        }),
      compatibility: metadata["compatibility"],
      predecessor: metadata["predecessor"],
      deprecation: metadata["deprecation"],
      rollback: metadata["rollback"],
      attribution_policy: metadata["attribution_policy"],
      attribution: tool.attribution,
      implementation_digest: implementation_digest,
      artifact_digest: String.duplicate("0", 64)
    }

    artifact = struct!(__MODULE__, fields)
    %{artifact | artifact_digest: artifact_digest(artifact)}
  end

  defp implementation_identity(module) when is_atom(module) do
    case :code.get_object_code(module) do
      {^module, bytes, _path} when is_binary(bytes) ->
        {:ok, Canonical.sha256(bytes), "loaded_beam"}

      :error ->
        module_identity(module)
    end
  end

  defp module_identity(module) do
    try do
      identity = :erlang.term_to_binary({module, module.module_info(:md5)})
      {:ok, Canonical.sha256(identity), "loaded_module_identity"}
    rescue
      _exception -> {:error, {:module_executor_bytes_unavailable, module}}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata) do
    required =
      ~w(state approval_class capability_scopes data_scopes facets publisher provenance compatibility predecessor deprecation rollback attribution_policy)

    if Enum.all?(required, &Map.has_key?(metadata, &1)),
      do: :ok,
      else: {:error, :module_metadata_incomplete}
  end

  defp validate_metadata(_metadata), do: {:error, :module_metadata_incomplete}

  defp validate_tool_alignment(tool) do
    metadata = tool.module_metadata

    cond do
      tool.required_authority not in metadata["capability_scopes"] ->
        {:error, :module_capability_scope_mismatch}

      tool.required_scope not in metadata["data_scopes"] ->
        {:error, :module_data_scope_mismatch}

      tool.side_effect == :reversible_write and
          metadata["approval_class"] != "exact_current_user_consent" ->
        {:error, :module_approval_mismatch}

      true ->
        :ok
    end
  end

  defp valid_provenance?(provenance, digest) when is_map(provenance) do
    non_empty?(provenance["source"]) and non_empty?(provenance["admission"]) and
      get_in(provenance, ["integrity", "algorithm"]) == "sha256" and
      get_in(provenance, ["integrity", "subject"]) in [
        "loaded_beam",
        "loaded_module_identity",
        "collective_generalized_payload"
      ] and
      get_in(provenance, ["integrity", "digest"]) == digest
  end

  defp valid_provenance?(_provenance, _digest), do: false

  defp valid_compatibility?(%{
         "runtime_min" => minimum,
         "runtime_max" => maximum,
         "dependencies" => dependencies
       }) do
    is_integer(minimum) and is_integer(maximum) and minimum <= @runtime_version and
      maximum >= @runtime_version and is_list(dependencies) and length(dependencies) <= 32 and
      Enum.all?(dependencies, &valid_dependency?/1)
  end

  defp valid_compatibility?(_compatibility), do: false

  defp valid_dependency?(%{"module_id" => id, "version" => version}),
    do: identifier?(id) and is_integer(version) and version > 0

  defp valid_dependency?(_dependency), do: false

  defp valid_optional_ref?(nil), do: true

  defp valid_optional_ref?(%{
         "module_id" => id,
         "version" => version,
         "artifact_digest" => digest
       }),
       do: identifier?(id) and is_integer(version) and version > 0 and valid_digest?(digest)

  defp valid_optional_ref?(_reference), do: false

  defp valid_deprecation?("deprecated", %{"reason" => reason, "replacement" => replacement}),
    do: non_empty?(reason) and valid_optional_ref?(replacement)

  defp valid_deprecation?(state, nil) when state != "deprecated", do: true
  defp valid_deprecation?(_state, _deprecation), do: false

  defp valid_attribution_policy?(
         %{
           "id" => id,
           "version" => version,
           "mode" => mode,
           "required" => required,
           "digest" => digest
         } = policy
       ) do
    expected = policy |> Map.delete("digest") |> Canonical.digest!()

    non_empty?(id) and is_integer(version) and version > 0 and non_empty?(mode) and
      is_boolean(required) and digest == expected
  end

  defp valid_attribution_policy?(_policy), do: false

  defp valid_executor?(executor, implementation_digest) when is_map(executor) do
    non_empty?(executor.id) and non_empty?(executor.disclosure) and
      non_empty?(executor.implementation) and
      executor.implementation_digest == implementation_digest
  end

  defp valid_executor?(_executor, _implementation_digest), do: false

  defp valid_schema?(schema), do: Schema.validate_schema(schema) == :ok

  defp complete_facets?(facets) when is_map(facets),
    do: Enum.all?(~w(cost quality residency privacy), &non_empty?(facets[&1]))

  defp complete_facets?(_facets), do: false

  defp valid_scopes?(scopes) when is_list(scopes) and scopes != [] and length(scopes) <= 32,
    do: Enum.all?(scopes, &identifier?/1)

  defp valid_scopes?(_scopes), do: false

  defp identifier?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and Regex.match?(@identifier_regex, value)

  defp non_empty?(value), do: is_binary(value) and byte_size(value) in 1..512
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_regex, value)
end
