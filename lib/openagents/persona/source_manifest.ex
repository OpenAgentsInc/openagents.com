defmodule OpenAgents.Persona.SourceManifest do
  @moduledoc """
  Loads and validates the immutable, status-labeled source manifest used to
  author Sarah's persona.

  The source documents remain in their repositories. This application pins
  their repository revision and content digest; it does not fetch them at
  runtime or treat them as runtime authority.
  """

  @schema "sarah.persona.source_manifest.v1"
  @manifest_id "sarah.persona.sources.v1"

  @authority_classes [
    %{
      "id" => "current_runtime_contracts",
      "status" => "binding",
      "resolution" => "deployed_release",
      "persona_input" => false
    },
    %{
      "id" => "admitted_persona_artifacts",
      "status" => "release_artifact",
      "resolution" => "pinned_by_id_and_digest",
      "persona_input" => true
    },
    %{
      "id" => "historical_sources",
      "status" => "status_labeled_evidence",
      "resolution" => "pinned_revision_path_and_digest",
      "persona_input" => true
    }
  ]

  @admitted_manifest_digests %{
    @manifest_id => "5a1ce30b0ce21b93858f8144277767c51c0b28aa053a9382c5877182481fa519"
  }

  @statuses ~w(
    accepted_audit
    final_sarah_script
    final_spoken_transcript
    founder_direction
    prepared_sarah_script
    quarantined_catalog_conflict
    recorded_founder_introduction
    retired_pattern_source
    scoped_performance
    source_hierarchy
    standing_voice_procedure
    unscheduled_design_draft
    voice_direction_profile
  )

  @admitted_uses ~w(
    architecture_pattern
    dataset_navigation
    delivery_direction
    evaluation_negative
    evaluation_positive
    identity
    memory_contract
    ordinary_voice
    product_intent
    role_pattern
    special_broadcast_only
    tool_contract
  )

  @exclusions ~w(
    action_authority
    current_capability_claim
    dataset_episode_mapping
    default_role
    identity
    ordinary_voice
    pricing_authority
    runtime_authority
    sarah_authored_speech
  )

  @required_source_ids ~w(
    acting-as-sarah-runbook
    blueprint-map-audit
    episode-260
    episode-261
    episode-262
    episode-263-conflict
    episode-268
    episode-269
    forking-zed-draft
    full-auto-draft
    nostr-memory-audit
    omega-agent-draft
    omega-alpha-final
    retired-sarah-contracts
    retired-sarah-knowledge-base
    sarah-corpus-readme
    transcript-catalog
    voice-direction-profile
  )

  @manifest_path "sarah/persona/sarah.v1.sources.json"
  @sha256_regex ~r/\A[0-9a-f]{64}\z/
  @revision_regex ~r/\A[0-9a-f]{40}\z/

  @type manifest :: map()
  @type reason :: atom() | tuple()

  @spec load() :: {:ok, manifest()} | {:error, reason()}
  def load do
    with {:ok, path} <- manifest_path(),
         {:ok, contents} <- read(path),
         {:ok, manifest} <- decode(contents),
         {:ok, validated_manifest} <- validate(manifest) do
      {:ok, validated_manifest}
    end
  end

  @spec load!() :: manifest()
  def load! do
    case load() do
      {:ok, manifest} ->
        manifest

      {:error, reason} ->
        raise ArgumentError, "invalid Sarah persona source manifest: #{inspect(reason)}"
    end
  end

  @spec validate(term()) :: {:ok, manifest()} | {:error, reason()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- validate_top_level(manifest),
         {:ok, sources} <- fetch_sources(manifest),
         :ok <- validate_sources(sources),
         :ok <- validate_required_sources(sources),
         :ok <- validate_special_sources(sources),
         :ok <- validate_manifest_digest(manifest) do
      {:ok, manifest}
    end
  end

  def validate(_manifest), do: {:error, :manifest_must_be_an_object}

  @doc "Returns the canonical digest of a decoded manifest, excluding its digest field."
  @spec calculate_digest(manifest()) :: String.t()
  def calculate_digest(manifest) when is_map(manifest) do
    manifest
    |> Map.delete("manifest_sha256")
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec source(manifest(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def source(%{"sources" => sources}, source_id) when is_list(sources) and is_binary(source_id) do
    case Enum.find(sources, &(&1["id"] == source_id)) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  def source(_manifest, _source_id), do: {:error, :not_found}

  defp manifest_path do
    case :code.priv_dir(:sarah) do
      path when is_list(path) -> {:ok, Path.join(List.to_string(path), @manifest_path)}
      {:error, reason} -> {:error, {:priv_dir_unavailable, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:manifest_read_failed, reason}}
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, _error} -> {:error, :manifest_json_invalid}
    end
  end

  defp validate_top_level(manifest) do
    cond do
      manifest["schema"] != @schema ->
        {:error, {:invalid_schema, manifest["schema"]}}

      manifest["id"] != @manifest_id ->
        {:error, {:invalid_manifest_id, manifest["id"]}}

      manifest["persona_id"] != "sarah.persona.v1" ->
        {:error, {:invalid_persona_id, manifest["persona_id"]}}

      manifest["revision"] != 1 ->
        {:error, {:invalid_manifest_revision, manifest["revision"]}}

      not valid_sha256?(manifest["manifest_sha256"]) ->
        {:error, :invalid_manifest_sha256}

      manifest["authority_order"] !=
          ["current_runtime_contracts", "admitted_persona_artifacts", "historical_sources"] ->
        {:error, :invalid_authority_order}

      manifest["authority_classes"] != @authority_classes ->
        {:error, :invalid_authority_classes}

      true ->
        :ok
    end
  end

  defp fetch_sources(%{"sources" => sources}) when is_list(sources) and sources != [],
    do: {:ok, sources}

  defp fetch_sources(_manifest), do: {:error, :sources_must_be_a_non_empty_array}

  defp validate_sources(sources) do
    with :ok <- validate_each_source(sources),
         :ok <- validate_unique(sources, "id", :duplicate_source_id),
         :ok <- validate_unique_identity(sources) do
      :ok
    end
  end

  defp validate_each_source(sources) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case validate_source(source) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_source(source) when is_map(source) do
    source_id = source["id"]

    cond do
      not non_empty_string?(source_id) ->
        {:error, :invalid_source_id}

      not non_empty_string?(source["repository"]) ->
        {:error, {:invalid_source_repository, source_id}}

      not Regex.match?(@revision_regex, source["revision"] || "") ->
        {:error, {:invalid_source_revision, source_id}}

      not valid_path?(source["path"]) ->
        {:error, {:invalid_source_path, source_id}}

      source["status"] not in @statuses ->
        {:error, {:invalid_source_status, source_id, source["status"]}}

      not valid_sha256?(source["content_sha256"]) ->
        {:error, {:invalid_source_content_sha256, source_id}}

      not valid_enum_list?(source["admitted_uses"], @admitted_uses) ->
        {:error, {:invalid_source_admitted_uses, source_id}}

      not valid_enum_list?(source["exclusions"], @exclusions) ->
        {:error, {:invalid_source_exclusions, source_id}}

      not non_empty_string?(source["note"]) ->
        {:error, {:invalid_source_note, source_id}}

      true ->
        :ok
    end
  end

  defp validate_source(_source), do: {:error, :source_must_be_an_object}

  defp validate_unique(sources, key, error) do
    values = Enum.map(sources, & &1[key])

    if length(values) == MapSet.size(MapSet.new(values)) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_unique_identity(sources) do
    identities = Enum.map(sources, &{&1["repository"], &1["revision"], &1["path"]})

    if length(identities) == MapSet.size(MapSet.new(identities)) do
      :ok
    else
      {:error, :duplicate_source_identity}
    end
  end

  defp validate_required_sources(sources) do
    source_ids = MapSet.new(sources, & &1["id"])

    case Enum.find(@required_source_ids, &(not MapSet.member?(source_ids, &1))) do
      nil -> :ok
      source_id -> {:error, {:missing_required_source, source_id}}
    end
  end

  defp validate_special_sources(sources) do
    with {:ok, episode_268} <- find_source(sources, "episode-268"),
         :ok <- validate_episode_268(episode_268),
         {:ok, episode_269} <- find_source(sources, "episode-269"),
         :ok <- validate_episode_269(episode_269),
         {:ok, episode_263} <- find_source(sources, "episode-263-conflict"),
         :ok <- validate_episode_263(episode_263),
         {:ok, omega_alpha} <- find_source(sources, "omega-alpha-final"),
         :ok <- validate_omega_alpha(omega_alpha) do
      :ok
    end
  end

  defp validate_episode_268(source) do
    if source["status"] == "scoped_performance" and
         "special_broadcast_only" in source["admitted_uses"] and
         "ordinary_voice" in source["exclusions"] and
         "default_role" in source["exclusions"] and
         "ordinary_voice" not in source["admitted_uses"] do
      :ok
    else
      {:error, :episode_268_must_remain_scoped}
    end
  end

  defp validate_episode_269(source) do
    if source["status"] == "founder_direction" and
         "product_intent" in source["admitted_uses"] and
         "architecture_pattern" in source["admitted_uses"] and
         "sarah_authored_speech" in source["exclusions"] and
         "ordinary_voice" in source["exclusions"] and
         "ordinary_voice" not in source["admitted_uses"] do
      :ok
    else
      {:error, :episode_269_must_remain_founder_direction}
    end
  end

  defp validate_episode_263(source) do
    if source["status"] == "quarantined_catalog_conflict" and
         source["admitted_uses"] == [] and
         "dataset_episode_mapping" in source["exclusions"] and
         "current_capability_claim" in source["exclusions"] do
      :ok
    else
      {:error, :episode_263_must_remain_quarantined}
    end
  end

  defp validate_omega_alpha(source) do
    if source["status"] == "final_spoken_transcript" and
         source["path"] == "docs/transcripts/26X-omega-alpha.md" and
         "identity" in source["admitted_uses"] and
         "ordinary_voice" in source["admitted_uses"] do
      :ok
    else
      {:error, :omega_alpha_must_be_pinned_by_path}
    end
  end

  defp find_source(sources, source_id) do
    case Enum.find(sources, &(&1["id"] == source_id)) do
      nil -> {:error, {:missing_required_source, source_id}}
      source -> {:ok, source}
    end
  end

  defp validate_manifest_digest(manifest) do
    declared_digest = manifest["manifest_sha256"]
    calculated_digest = calculate_digest(manifest)
    admitted_digest = @admitted_manifest_digests[manifest["id"]]

    cond do
      declared_digest != calculated_digest -> {:error, :manifest_digest_mismatch}
      declared_digest != admitted_digest -> {:error, :manifest_digest_not_admitted}
      true -> :ok
    end
  end

  defp valid_path?(path) when is_binary(path) do
    path != "" and Path.type(path) != :absolute and ".." not in Path.split(path)
  end

  defp valid_path?(_path), do: false

  defp valid_sha256?(digest), do: is_binary(digest) and Regex.match?(@sha256_regex, digest)

  defp valid_enum_list?(values, allowed) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and &1 in allowed)) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp valid_enum_list?(_values, _allowed), do: false

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
