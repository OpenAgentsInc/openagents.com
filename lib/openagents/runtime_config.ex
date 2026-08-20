defmodule OpenAgents.RuntimeConfig do
  @moduledoc """
  Typed, fail-closed boundary for behavior-changing runtime configuration.

  The boundary validates application configuration before migrations, workers,
  or the endpoint start. Its readiness report contains only environment,
  feature booleans, and group status; secret and infrastructure values never
  enter the report or validation errors.
  """

  alias OpenAgents.Forge.HotLoader
  alias OpenAgents.Forge.RollingProvider.Gcp
  alias OpenAgents.Tools.Snapshot

  @persistent_key {__MODULE__, :current}
  @target_repository "openagents.com"
  @target_owner "OpenAgentsInc"
  @environments [:development, :test, :staging, :production]
  @group_names ~w(endpoint database github providers features forge cluster)a

  @enforce_keys [:environment, :staging_gate, :features, :groups]
  defstruct @enforce_keys ++ [:hot_load_allowlist, :hot_load_examples]

  @type t :: %__MODULE__{
          environment: :development | :test | :staging | :production,
          staging_gate: 0..16,
          features: %{required(atom()) => boolean()},
          groups: %{required(atom()) => :ready},
          hot_load_allowlist: [String.t()],
          hot_load_examples: %{required(String.t()) => boolean()}
        }

  @spec install!() :: t()
  def install! do
    config = load!() |> verify_compiled_settings!()
    :persistent_term.put(@persistent_key, config)
    config
  end

  @spec current!() :: t()
  def current! do
    case :persistent_term.get(@persistent_key, :not_installed) do
      %__MODULE__{} = config -> config
      :not_installed -> raise "runtime configuration is not installed"
    end
  end

  @spec load!(keyword() | map()) :: t()
  def load!(settings \\ Application.get_all_env(:openagents)) do
    case validate(settings) do
      {:ok, config} ->
        config

      {:error, %{setting: setting, reason: reason}} ->
        raise ArgumentError, "runtime configuration invalid: #{setting} #{reason}"
    end
  end

  @spec validate(keyword() | map()) :: {:ok, t()} | {:error, map()}
  def validate(settings) when is_list(settings) or is_map(settings) do
    settings = Map.new(settings)

    with {:ok, environment} <- required_enum(settings, :runtime_environment, @environments),
         {:ok, staging_gate} <- required_integer(settings, :staging_gate, 0..16),
         :ok <- validate_production_lock(settings, environment),
         :ok <- validate_endpoint(settings, environment),
         :ok <- validate_database(settings, environment),
         :ok <- validate_github(settings, environment),
         {:ok, features} <- validate_features(settings, environment, staging_gate),
         :ok <- validate_providers(settings, features),
         :ok <- validate_release_identity(settings, environment, staging_gate),
         {:ok, allowlist, examples} <- validate_forge(settings, environment, features),
         :ok <- validate_cluster(settings, environment, features) do
      {:ok,
       %__MODULE__{
         environment: environment,
         staging_gate: staging_gate,
         features: features,
         groups: Map.new(@group_names, &{&1, :ready}),
         hot_load_allowlist: allowlist,
         hot_load_examples: examples
       }}
    end
  end

  def validate(_settings), do: error(:application_environment, "must be a map or keyword list")

  @spec feature_enabled?(atom()) :: boolean()
  def feature_enabled?(feature), do: feature_enabled?(current!(), feature)

  @spec feature_enabled?(t(), atom()) :: boolean()
  def feature_enabled?(%__MODULE__{features: features}, feature),
    do: Map.fetch!(features, feature)

  @spec fetch_secret(:openai_api_key) :: {:ok, String.t()} | {:error, :not_configured}
  def fetch_secret(:openai_api_key) do
    case Application.fetch_env(:openagents, :openai_api_key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _missing -> {:error, :not_configured}
    end
  end

  @spec readiness_report(t()) :: map()
  def readiness_report(config \\ current!()) do
    %{
      "schema" => "openagents.runtime_configuration.v1",
      "status" => "ready",
      "environment" => Atom.to_string(config.environment),
      "staging_gate" => config.staging_gate,
      "groups" =>
        Map.new(config.groups, fn {name, status} -> {to_string(name), to_string(status)} end),
      "features" =>
        Map.new(config.features, fn {name, enabled?} -> {to_string(name), enabled?} end)
    }
  end

  @spec print_readiness!() :: :ok
  def print_readiness! do
    load!()
    |> verify_compiled_settings!()
    |> readiness_report()
    |> Jason.encode!()
    |> IO.puts()
  end

  @spec verify_startup!(t(), Snapshot.t()) :: :ok
  def verify_startup!(%__MODULE__{} = config, %Snapshot{} = snapshot) do
    if feature_enabled?(config, :tools) and map_size(snapshot.tools) == 0 do
      raise ArgumentError, "runtime self-test failed: tools catalog is empty"
    end

    Enum.each(config.hot_load_examples, fn {module_name, expected?} ->
      if HotLoader.allowlisted?(module_name, config.hot_load_allowlist) != expected? do
        raise ArgumentError,
              "runtime self-test failed: forge_hot_load_examples classification mismatch"
      end
    end)

    :ok
  end

  defp validate_production_lock(settings, :production) do
    case Map.fetch(settings, :production_deploy_enabled) do
      {:ok, true} -> :ok
      _locked -> error(:production_deploy_enabled, "must be explicitly true for production")
    end
  end

  defp validate_production_lock(_settings, _environment), do: :ok

  defp validate_release_identity(settings, environment, staging_gate) do
    required? = environment == :production or (environment == :staging and staging_gate >= 12)
    revision = Map.get(settings, :build_revision)
    image_digest = Map.get(settings, :image_digest)

    cond do
      not required? ->
        :ok

      not exact_sha?(revision) ->
        error(:build_revision, "must identify the exact packaged Git commit")

      not image_digest?(image_digest) ->
        error(:image_digest, "must identify the immutable packaged image")

      true ->
        :ok
    end
  end

  defp verify_compiled_settings!(%__MODULE__{environment: environment} = config)
       when environment in [:staging, :production] do
    if keyword_value(OpenAgentsWeb.Endpoint.session_options(), :secure) == true do
      config
    else
      raise ArgumentError, "runtime configuration invalid: secure_cookies must be compiled true"
    end
  end

  defp verify_compiled_settings!(%__MODULE__{} = config), do: config

  defp validate_endpoint(settings, environment) do
    endpoint = Map.get(settings, OpenAgentsWeb.Endpoint, [])
    url = keyword_value(endpoint, :url, [])
    host = keyword_value(url, :host)
    check_origin = keyword_value(endpoint, :check_origin)
    secure_cookies = Map.get(settings, :secure_cookies)
    aliases = Map.get(settings, :https_aliases)

    cond do
      not hostname?(host) ->
        error(:endpoint_host, "must be a valid hostname")

      not (is_list(aliases) and Enum.all?(aliases, &hostname?/1)) ->
        error(:https_aliases, "must be a list of hostnames")

      environment in [:staging, :production] and secure_cookies != true ->
        error(:secure_cookies, "must be true")

      environment == :staging and host != "stage.openagents.com" ->
        error(:endpoint_host, "must be the staging hostname")

      environment in [:staging, :production] and
          not valid_origins?(check_origin, host, aliases) ->
        error(:allowed_origins, "must contain every exact HTTPS public origin")

      true ->
        :ok
    end
  end

  defp validate_database(settings, environment) do
    repo = Map.get(settings, OpenAgents.Repo, [])
    migrate? = Map.get(settings, :migrate_on_boot)

    connection? =
      case keyword_value(repo, :url) do
        value when is_binary(value) -> database_url?(value)
        nil -> socket_database?(repo)
        _invalid -> false
      end

    cond do
      not connection? ->
        error(:database_connection, "must be a PostgreSQL URL or complete socket configuration")

      environment in [:staging, :production] and migrate? != true ->
        error(:migrate_on_boot, "must be true")

      true ->
        :ok
    end
  end

  defp validate_github(settings, environment) do
    oauth = Map.get(settings, :github_oauth, [])
    client_id = keyword_value(oauth, :client_id)
    client_secret = keyword_value(oauth, :client_secret)
    redirect_uri = keyword_value(oauth, :redirect_uri)
    scopes = Map.get(settings, :github_oauth_scopes)
    token_key = Map.get(settings, :github_token_encryption_key)
    token_key_id = Map.get(settings, :github_token_encryption_key_id)
    decryption_keys = Map.get(settings, :github_token_decryption_keys)

    with :ok <- ensure(present?(client_id), :github_oauth_client_id, "is required"),
         :ok <- ensure(present?(client_secret), :github_oauth_client_secret, "is required"),
         :ok <- validate_redirect(redirect_uri, environment),
         :ok <-
           ensure(
             scopes == ["repo"],
             :github_oauth_scopes,
             "must match the retained-token tool model"
           ),
         :ok <-
           ensure(
             encryption_key?(token_key),
             :github_token_encryption_key,
             "must be a base64-encoded 32-byte key"
           ),
         :ok <-
           ensure(
             token_key_id_for_environment?(token_key_id, environment),
             :github_token_encryption_key_id,
             "must be a bounded key identifier prefixed for the runtime environment"
           ),
         :ok <-
           ensure(
             decryption_keyring?(decryption_keys, token_key_id, environment),
             :github_token_decryption_keys,
             "must contain only bounded identifiers and base64-encoded 32-byte keys"
           ) do
      :ok
    end
  end

  defp token_key_id?(key_id) when is_binary(key_id),
    do: String.match?(key_id, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/)

  defp token_key_id?(_key_id), do: false

  defp token_key_id_for_environment?(key_id, environment) do
    token_key_id?(key_id) and String.starts_with?(key_id, Atom.to_string(environment) <> "-")
  end

  defp decryption_keyring?(keys, active_key_id, environment) when is_map(keys) do
    map_size(keys) <= 16 and not Map.has_key?(keys, active_key_id) and
      Enum.all?(keys, fn {key_id, key} ->
        token_key_id_for_environment?(key_id, environment) and encryption_key?(key)
      end)
  end

  defp decryption_keyring?(_keys, _active_key_id, _environment), do: false

  defp exact_sha?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp exact_sha?(_value), do: false

  defp image_digest?(value) when is_binary(value),
    do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp image_digest?(_value), do: false

  defp validate_features(settings, environment, staging_gate) do
    with {:ok, tools?} <- required_boolean(settings, :tools_enabled),
         {:ok, voice?} <- nested_boolean(settings, :voice, :enabled),
         {:ok, recording?} <- nested_boolean(settings, :voice_recording, :enabled),
         {:ok, work?} <- nested_boolean(settings, :work, :enabled),
         {:ok, semantic?} <- nested_boolean(settings, :semantic_index, :enabled),
         {:ok, experience?} <- nested_boolean(settings, :experience_memory, :enabled),
         {:ok, graph?} <- nested_boolean(settings, :graph_memory, :enabled),
         {:ok, portability?} <- nested_boolean(settings, :memory_portability, :enabled),
         {:ok, shadow?} <- nested_boolean(settings, :shadow_programs, :enabled),
         {:ok, tool_embeddings?} <-
           nested_boolean(settings, :tool_discovery, :embeddings_enabled),
         {:ok, forge?} <- required_boolean(settings, :forge_enabled),
         {:ok, forge_deploy?} <- required_boolean(settings, :forge_deploy_lane_enabled),
         {:ok, boot_convergence?} <- required_boolean(settings, :forge_boot_converge_enabled),
         {:ok, turn_recovery?} <- required_boolean(settings, :turn_recovery_enabled),
         {:ok, voice_retention?} <- required_boolean(settings, :voice_retention_enabled),
         {:ok, voice_recovery?} <-
           required_boolean(settings, :voice_recovery_worker_enabled),
         {:ok, work_workers?} <- required_boolean(settings, :work_workers_enabled),
         {:ok, computers?} <- required_boolean(settings, :computer_controller_enabled),
         {:ok, conversation_reset?} <-
           required_boolean(settings, :conversation_reset_enabled),
         {:ok, incident_fixer?} <- required_boolean(settings, :incident_fixer_enabled),
         {:ok, ra?} <- required_boolean(settings, :ra_enabled) do
      features = %{
        tools: tools?,
        voice: voice?,
        voice_recording: recording?,
        voice_retention: voice_retention?,
        work: work?,
        computers: computers?,
        semantic_memory: semantic?,
        experience_memory: experience?,
        graph_memory: graph?,
        memory_portability: portability?,
        shadow_programs: shadow?,
        tool_embeddings: tool_embeddings?,
        forge: forge?,
        forge_deploy: forge_deploy?,
        boot_convergence: boot_convergence?,
        turn_recovery: turn_recovery?,
        voice_recovery: voice_recovery?,
        work_workers: work_workers?,
        conversation_reset: conversation_reset?,
        incident_fixer: incident_fixer?,
        ra: ra?
      }

      case validate_feature_combinations(features, settings, environment, staging_gate) do
        :ok -> {:ok, features}
        {:error, _details} = error -> error
      end
    end
  end

  defp validate_feature_combinations(features, settings, environment, staging_gate) do
    early_staging_features =
      Enum.filter(
        [
          :voice,
          :voice_recording,
          :work,
          :computers,
          :semantic_memory,
          :experience_memory,
          :graph_memory,
          :memory_portability,
          :shadow_programs,
          :tool_embeddings,
          :conversation_reset,
          :incident_fixer
        ],
        &features[&1]
      )

    cond do
      not valid_feature_domains?(settings) ->
        error(:feature_configuration, "contains invalid limits or provider settings")

      environment in [:staging, :production] and features.voice_recording and
          not features.voice ->
        error(:voice_recording, "cannot be enabled while voice is disabled")

      features.voice_recording and
          not encryption_key?(Map.get(settings, :voice_recording_encryption_key)) ->
        error(:voice_recording_encryption_key, "is required when recording is enabled")

      features.voice_retention and not features.voice_recording ->
        error(:voice_retention_enabled, "requires voice recording")

      features.voice_recovery and not features.voice ->
        error(:voice_recovery_worker_enabled, "requires voice")

      features.work_workers != features.work ->
        error(:work_workers_enabled, "must match the work feature")

      environment in [:staging, :production] and features.computers and
          not clean_service_url?(Map.get(settings, :inference_proxy_url)) ->
        error(:inference_proxy_url, "must be an HTTPS URL without credentials")

      environment in [:staging, :production] and
        (features.work or features.computers) and
          not durable_path?(Map.get(settings, :coding_jobs_dir)) ->
        error(:coding_jobs_dir, "must be durable when work or computers are enabled")

      features.incident_fixer and not features.computers ->
        error(:incident_fixer_enabled, "requires computers")

      features.forge_deploy and not features.forge ->
        error(:forge_deploy_lane_enabled, "requires the forge")

      features.boot_convergence and not features.forge_deploy ->
        error(:forge_boot_converge_enabled, "requires the forge deployment lane")

      environment == :staging and staging_gate < 14 and early_staging_features != [] ->
        error(
          :staging_gate,
          "does not admit advanced product features"
        )

      environment == :staging and staging_gate < 13 and
          (features.forge_deploy or features.boot_convergence) ->
        error(:staging_gate, "does not admit forge deployment or boot convergence")

      environment == :staging and staging_gate < 12 and features.ra ->
        error(:staging_gate, "does not admit Ra")

      true ->
        :ok
    end
  end

  defp validate_providers(settings, features) do
    provider = Map.get(settings, :provider)
    model = Map.get(settings, :openai_model)
    openai_key = Map.get(settings, :openai_api_key)
    voice = Map.get(settings, :voice, [])
    shadow = Map.get(settings, :shadow_programs, [])
    semantic = Map.get(settings, :semantic_index, [])

    needs_openai? =
      provider == OpenAgents.Providers.OpenAI or features.voice or features.shadow_programs or
        features.semantic_memory or features.tool_embeddings

    cond do
      not is_atom(provider) ->
        error(:provider, "must be a module")

      not (is_binary(model) and byte_size(model) in 1..128) ->
        error(:openai_model, "must be a bounded model identifier")

      needs_openai? and not present?(openai_key) ->
        error(:openai_api_key, "is required by an enabled OpenAI provider")

      not valid_voice_config?(voice) ->
        error(:voice, "has invalid admission settings")

      not valid_shadow_config?(shadow) ->
        error(:shadow_programs, "has invalid settings")

      not valid_semantic_config?(semantic) ->
        error(:semantic_index, "has invalid settings")

      true ->
        :ok
    end
  end

  defp validate_forge(settings, environment, features) do
    repos = Map.get(settings, :forge_repos)
    owners = Map.get(settings, :forge_repo_owners)
    visibility = Map.get(settings, :forge_public_visibility)
    paths = Map.get(settings, :forge_public_paths)
    internal_url = Map.get(settings, :forge_internal_git_url)
    allowlist = Map.get(settings, :forge_hot_load_allowlist)
    examples = Map.get(settings, :forge_hot_load_examples)
    expected_fleet_size = Map.get(settings, :forge_expected_fleet_size)
    artifact_store = Map.get(settings, :forge_artifact_store)
    build_executor = Map.get(settings, :forge_build_executor)
    deploy_timeout_ms = Map.get(settings, :forge_deploy_timeout_ms)
    deploy_token_ttl_ms = Map.get(settings, :forge_deploy_token_ttl_ms)
    boot_retry_min_ms = Map.get(settings, :forge_boot_retry_min_ms)
    boot_retry_max_ms = Map.get(settings, :forge_boot_retry_max_ms)
    operator_token = Map.get(settings, :forge_operator_token)
    mirror_urls = Map.get(settings, :forge_mirror_urls)
    rolling_provider = Map.get(settings, :forge_rolling_provider)
    rolling_provider_config = Map.get(settings, Gcp, [])
    durable_required? = environment in [:staging, :production] and features.forge

    with :ok <-
           ensure(valid_repositories?(repos), :forge_repos, "must list valid repository names"),
         :ok <-
           ensure(
             target_repository?(repos, owners, visibility, paths),
             :forge_target_repository,
             "must be OpenAgentsInc/openagents.com"
           ),
         :ok <-
           ensure(
             clean_internal_url?(internal_url),
             :forge_internal_git_url,
             "must be an HTTP URL without credentials"
           ),
         :ok <-
           ensure(
             clean_mirror_urls?(mirror_urls),
             :forge_mirror_urls,
             "must contain only credential-free git remote URLs or paths"
           ),
         :ok <-
           ensure(
             valid_allowlist?(allowlist),
             :forge_hot_load_allowlist,
             "must contain module names or prefixes"
           ),
         :ok <-
           ensure(
             valid_examples?(examples, allowlist),
             :forge_hot_load_examples,
             "must classify every example as configured"
           ),
         :ok <-
           ensure(
             is_integer(expected_fleet_size) and expected_fleet_size in 1..100,
             :forge_expected_fleet_size,
             "must be between 1 and 100"
           ),
         :ok <-
           ensure(
             artifact_store in [:local, :gcs],
             :forge_artifact_store,
             "must be a supported store"
           ),
         :ok <-
           ensure(
             is_atom(build_executor),
             :forge_build_executor,
             "must be a module"
           ),
         :ok <-
           ensure(
             is_integer(deploy_timeout_ms) and deploy_timeout_ms in 1_000..120_000,
             :forge_deploy_timeout_ms,
             "must be between 1 and 120 seconds"
           ),
         :ok <-
           ensure(
             is_integer(deploy_token_ttl_ms) and deploy_token_ttl_ms in 30_000..1_800_000 and
               deploy_token_ttl_ms >= deploy_timeout_ms * 8,
             :forge_deploy_token_ttl_ms,
             "must cover eight deployment phase timeouts"
           ),
         :ok <-
           ensure(
             is_integer(boot_retry_min_ms) and is_integer(boot_retry_max_ms) and
               boot_retry_min_ms in 100..60_000 and boot_retry_max_ms in 1_000..300_000 and
               boot_retry_min_ms <= boot_retry_max_ms,
             :forge_boot_retry_bounds,
             "must define an ordered bounded backoff"
           ),
         :ok <-
           ensure(
             not features.forge_deploy or expected_fleet_size >= 2,
             :forge_expected_fleet_size,
             "must include a canary and peer for deployment"
           ),
         :ok <- validate_rolling_provider(rolling_provider, rolling_provider_config, features),
         :ok <- validate_forge_secrets(operator_token, durable_required? or features.forge_deploy),
         :ok <- validate_forge_paths(settings, durable_required? or features.forge_deploy),
         :ok <- validate_wal(settings, durable_required? or features.forge_deploy) do
      {:ok, allowlist, examples}
    end
  end

  defp validate_rolling_provider(_provider, _config, %{forge_deploy: false}), do: :ok

  defp validate_rolling_provider(Gcp, config, %{forge_deploy: true}) do
    case Gcp.validate_config(config) do
      :ok -> :ok
      {:error, _reason} -> error(:forge_rolling_provider, "must use an isolated staging project")
    end
  end

  defp validate_rolling_provider(_provider, _config, %{forge_deploy: true}),
    do: error(:forge_rolling_provider, "must be the admitted infrastructure provider")

  defp validate_forge_secrets(operator_token, true) do
    if present?(operator_token),
      do: :ok,
      else: error(:forge_operator_token, "is required while the forge is enabled")
  end

  defp validate_forge_secrets(_operator_token, false), do: :ok

  defp validate_forge_paths(settings, true) do
    keys = [:forge_data_dir, :forge_build_dir, :forge_build_queue_dir, :forge_artifact_dir]

    if Enum.all?(keys, &durable_path?(Map.get(settings, &1))) do
      :ok
    else
      error(:forge_storage_paths, "must be absolute and outside temporary storage")
    end
  end

  defp validate_forge_paths(_settings, false), do: :ok

  defp validate_wal(settings, true) do
    case Map.get(settings, :forge_wal_adapter) do
      OpenAgents.Forge.WAL.Local ->
        if durable_path?(Map.get(settings, :forge_wal_dir)),
          do: :ok,
          else: error(:forge_wal_dir, "must be durable for the local WAL")

      OpenAgents.Forge.WAL.Gcs ->
        if present?(Map.get(settings, :forge_wal_bucket)) and
             is_atom(Map.get(settings, :forge_gcs_token_provider)),
           do: :ok,
           else: error(:forge_wal, "requires a bucket and token provider")

      _invalid ->
        error(:forge_wal_adapter, "must be a supported adapter")
    end
  end

  defp validate_wal(_settings, false), do: :ok

  defp validate_cluster(settings, environment, features) do
    horde? = Map.get(settings, :horde_enabled)
    expected = Map.get(settings, :ra_expected_size)
    data_dir = Map.get(settings, :ra_data_dir)
    dns_query = Map.get(settings, :dns_cluster_query)
    distribution = Map.get(settings, :distribution, [])
    distributed_feature? = features.ra or features.forge_deploy

    cond do
      not is_boolean(horde?) ->
        error(:horde_enabled, "must be boolean")

      not (is_integer(expected) and expected in 1..100) ->
        error(:ra_expected_size, "must be between 1 and 100")

      features.ra and expected < 3 ->
        error(:ra_expected_size, "must admit a quorum")

      features.ra and environment in [:staging, :production] and not durable_path?(data_dir) ->
        error(:ra_data_dir, "must be durable")

      features.ra and not present?(dns_query) ->
        error(:dns_cluster_query, "is required when Ra is enabled")

      distributed_feature? and not horde? ->
        error(:horde_enabled, "is required for distributed features")

      features.forge_deploy and not present?(dns_query) ->
        error(:dns_cluster_query, "is required for fleet deployment")

      distributed_feature? and not valid_distribution?(distribution) ->
        error(:distribution, "must configure node name, cookie, and bounded ports")

      true ->
        :ok
    end
  end

  defp required_enum(settings, key, allowed) do
    case Map.fetch(settings, key) do
      {:ok, value} ->
        if value in allowed,
          do: {:ok, value},
          else: error(key, "must be one of the admitted values")

      _invalid ->
        error(key, "must be one of the admitted values")
    end
  end

  defp required_integer(settings, key, range) do
    case Map.fetch(settings, key) do
      {:ok, value} when is_integer(value) ->
        if value in range,
          do: {:ok, value},
          else: error(key, "must be within the admitted range")

      _invalid ->
        error(key, "must be within the admitted range")
    end
  end

  defp required_boolean(settings, key) do
    case Map.fetch(settings, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _invalid -> error(key, "must be boolean")
    end
  end

  defp nested_boolean(settings, key, nested_key) do
    case Map.fetch(settings, key) do
      {:ok, values} when is_list(values) ->
        case Keyword.fetch(values, nested_key) do
          {:ok, value} when is_boolean(value) -> {:ok, value}
          _invalid -> error(key, "must contain a boolean #{nested_key}")
        end

      _invalid ->
        error(key, "must be a keyword list")
    end
  end

  defp validate_redirect(redirect_uri, environment) do
    case URI.new(redirect_uri) do
      {:ok,
       %URI{
         scheme: scheme,
         host: host,
         path: "/auth/github/callback",
         query: nil,
         fragment: nil,
         userinfo: nil
       }}
      when is_binary(host) and
             (scheme == "https" or
                (environment in [:development, :test] and scheme == "http" and
                   host in ["127.0.0.1", "localhost"])) ->
        :ok

      _invalid ->
        error(:github_oauth_redirect_uri, "must be an exact admitted callback")
    end
  end

  defp valid_origins?(origins, host, aliases) when is_list(origins) and is_list(aliases) do
    required = Enum.map([host | aliases], &"https://#{&1}")
    Enum.all?(origins, &https_origin?/1) and Enum.all?(required, &(&1 in origins))
  end

  defp valid_origins?(_origins, _host, _aliases), do: false

  defp https_origin?(origin) do
    case URI.new(origin) do
      {:ok,
       %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil, userinfo: nil}}
      when is_binary(host) and path in [nil, "", "/"] ->
        true

      _invalid ->
        false
    end
  end

  defp database_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["ecto", "postgres", "postgresql"] ->
        present?(host)

      _invalid ->
        false
    end
  end

  defp socket_database?(settings) do
    Enum.all?([:username, :database, :socket_dir], &present?(keyword_value(settings, &1))) and
      is_integer(keyword_value(settings, :pool_size))
  end

  defp valid_voice_config?(settings) when is_list(settings) do
    architecture = keyword_value(settings, :architecture)
    provider = keyword_value(settings, :provider)
    model = keyword_value(settings, :model)
    voice = keyword_value(settings, :voice)
    effort = keyword_value(settings, :reasoning_effort)
    duration = keyword_value(settings, :maximum_session_seconds)

    architecture == :openai_realtime and provider == "openai" and model == "gpt-realtime-2.1" and
      voice in ["marin", "cedar"] and effort in ["low", "medium", "high"] and
      is_integer(duration) and duration in 1..3_300
  end

  defp valid_voice_config?(_settings), do: false

  defp valid_shadow_config?(settings) when is_list(settings) do
    is_boolean(keyword_value(settings, :enabled)) and is_atom(keyword_value(settings, :provider)) and
      is_integer(keyword_value(settings, :timeout_ms)) and
      keyword_value(settings, :timeout_ms) in 100..60_000
  end

  defp valid_shadow_config?(_settings), do: false

  defp valid_semantic_config?(settings) when is_list(settings) do
    is_boolean(keyword_value(settings, :enabled)) and is_atom(keyword_value(settings, :provider)) and
      present?(keyword_value(settings, :model_id)) and
      present?(keyword_value(settings, :model_version)) and
      is_integer(keyword_value(settings, :dimensions)) and
      keyword_value(settings, :dimensions) in 1..4_096 and
      is_integer(keyword_value(settings, :batch_size)) and
      keyword_value(settings, :batch_size) in 1..1_000 and
      is_integer(keyword_value(settings, :poll_interval_ms)) and
      keyword_value(settings, :poll_interval_ms) in 100..60_000 and
      is_integer(keyword_value(settings, :provider_timeout_ms)) and
      keyword_value(settings, :provider_timeout_ms) in 100..120_000 and
      is_integer(keyword_value(settings, :lease_ms)) and
      keyword_value(settings, :lease_ms) in keyword_value(settings, :provider_timeout_ms)..300_000
  end

  defp valid_semantic_config?(_settings), do: false

  defp valid_feature_domains?(settings) do
    recording = Map.get(settings, :voice_recording, [])
    experience = Map.get(settings, :experience_memory, [])
    graph = Map.get(settings, :graph_memory, [])
    discovery = Map.get(settings, :tool_discovery, [])
    maximum_chunk_bytes = keyword_value(recording, :maximum_chunk_bytes)
    maximum_bytes = keyword_value(recording, :maximum_bytes)

    keyword_integer_in?(recording, :timeslice_ms, 250..60_000) and
      keyword_integer_in?(recording, :maximum_chunk_bytes, 1..10_485_760) and
      keyword_integer_in?(recording, :maximum_chunks, 1..4_096) and
      is_integer(maximum_bytes) and is_integer(maximum_chunk_bytes) and
      maximum_bytes in maximum_chunk_bytes..10_737_418_240 and
      keyword_integer_in?(recording, :late_chunk_grace_seconds, 1..3_600) and
      keyword_integer_in?(recording, :retention_days, 1..365) and
      keyword_integer_in?(experience, :maximum_records, 1..50) and
      keyword_integer_in?(experience, :maximum_patterns, 1..20) and
      keyword_integer_in?(experience, :maximum_bytes, 256..65_536) and
      keyword_integer_in?(graph, :maximum_nodes, 1..10_000) and
      keyword_integer_in?(graph, :maximum_depth, 1..20) and
      keyword_integer_in?(graph, :maximum_export_artifacts, 1..100_000) and
      is_boolean(keyword_value(discovery, :embeddings_enabled)) and
      is_atom(keyword_value(discovery, :provider)) and
      present?(keyword_value(discovery, :model_id)) and
      present?(keyword_value(discovery, :model_version)) and
      keyword_integer_in?(discovery, :dimensions, 1..4_096) and
      keyword_integer_in?(discovery, :top_k, 1..64) and
      integer_setting_in?(settings, :conversation_page_size, 1..200) and
      integer_setting_in?(settings, :maximum_message_bytes, 1..1_048_576) and
      integer_setting_in?(settings, :turn_rate_limit, 1..10_000) and
      integer_setting_in?(settings, :inference_grant_max_total_tokens, 1..100_000_000) and
      integer_setting_in?(settings, :inference_grant_max_calls, 1..10_000) and
      integer_setting_in?(settings, :inference_grant_max_cost_microusd, 1..1_000_000_000) and
      integer_setting_in?(settings, :inference_grant_ttl_seconds, 1..86_400) and
      integer_setting_in?(settings, :machine_token_ttl_seconds, 300..2_592_000)
  end

  defp keyword_integer_in?(settings, key, range) do
    value = keyword_value(settings, key)
    is_integer(value) and value in range
  end

  defp integer_setting_in?(settings, key, range) do
    value = Map.get(settings, key)
    is_integer(value) and value in range
  end

  defp valid_repositories?(repos) when is_list(repos) and repos != [] do
    Enum.all?(repos, &Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/, &1)) and
      length(repos) == length(Enum.uniq(repos))
  end

  defp valid_repositories?(_repos), do: false

  defp target_repository?(repos, owners, visibility, paths)
       when is_list(repos) and is_map(owners) and is_map(visibility) and is_map(paths) do
    @target_repository in repos and owners[@target_repository] == @target_owner and
      Map.has_key?(visibility, @target_repository) and Map.has_key?(paths, @target_repository)
  end

  defp target_repository?(_repos, _owners, _visibility, _paths), do: false

  defp clean_internal_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) ->
        true

      _invalid ->
        false
    end
  end

  defp clean_mirror_urls?(urls) when is_map(urls) do
    Enum.all?(urls, fn {repo, url} ->
      is_binary(repo) and clean_mirror_url?(url)
    end)
  end

  defp clean_mirror_urls?(_urls), do: false

  defp clean_mirror_url?(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    cond do
      String.contains?(url, ["\n", "\r", "\0"]) ->
        false

      Path.type(url) == :absolute ->
        true

      true ->
        match?(
          {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
          when scheme in ["http", "https", "git", "ssh"] and is_binary(host),
          URI.new(url)
        )
    end
  end

  defp clean_mirror_url?(_url), do: false

  defp clean_service_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) -> true
      _invalid -> false
    end
  end

  defp valid_allowlist?(allowlist) when is_list(allowlist) and allowlist != [] do
    Enum.all?(allowlist, fn entry ->
      is_binary(entry) and Regex.match?(~r/\A[A-Z][A-Za-z0-9_.]*\z/, entry) and
        not String.contains?(entry, ["/", "\\"])
    end)
  end

  defp valid_allowlist?(_allowlist), do: false

  defp valid_examples?(examples, allowlist) when is_map(examples) do
    map_size(examples) >= 2 and
      Enum.all?(examples, fn {module_name, expected?} ->
        is_binary(module_name) and is_boolean(expected?) and
          HotLoader.allowlisted?(module_name, allowlist) == expected?
      end)
  end

  defp valid_examples?(_examples, _allowlist), do: false

  defp valid_distribution?(settings) when is_list(settings) do
    min = keyword_value(settings, :port_min)
    max = keyword_value(settings, :port_max)

    keyword_value(settings, :enabled) == true and
      keyword_value(settings, :node_configured) == true and
      keyword_value(settings, :cookie_configured) == true and is_integer(min) and
      is_integer(max) and min in 1_024..65_535 and max in min..65_535 and max - min <= 100
  end

  defp valid_distribution?(_settings), do: false

  defp hostname?(value) when is_binary(value) do
    byte_size(value) in 1..253 and
      Regex.match?(
        ~r/\A(?=.{1,253}\z)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/,
        value
      )
  end

  defp hostname?(_value), do: false

  defp encryption_key?(value) when is_binary(value) do
    match?({:ok, key} when byte_size(key) == 32, Base.decode64(value))
  end

  defp encryption_key?(_value), do: false

  defp durable_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and path != "/" and
      not (path == "/tmp" or String.starts_with?(path, "/tmp/"))
  end

  defp durable_path?(_path), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp keyword_value(values, key, default \\ nil)

  defp keyword_value(values, key, default) when is_list(values),
    do: Keyword.get(values, key, default)

  defp keyword_value(_values, _key, default), do: default

  defp ensure(true, _setting, _reason), do: :ok
  defp ensure(false, setting, reason), do: error(setting, reason)

  defp error(setting, reason), do: {:error, %{setting: setting, reason: reason}}
end
