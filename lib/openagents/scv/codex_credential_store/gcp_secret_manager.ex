defmodule OpenAgents.SCV.CodexCredentialStore.GcpSecretManager do
  @moduledoc "Google Secret Manager storage for versioned SCV Codex authentication homes."

  @behaviour OpenAgents.SCV.CodexCredentialStore

  alias OpenAgents.SCV.DriverAccount

  @impl true
  def put(%DriverAccount{} = account, auth_json) when is_binary(auth_json) do
    with {:ok, secret_ref} <- secret_ref(account),
         {:ok, token} <- access_token(),
         {:ok, response} <-
           Req.post(
             request_options(
               url: "#{api_base()}/v1/#{secret_ref}:addVersion",
               auth: {:bearer, token},
               json: %{payload: %{data: Base.encode64(auth_json)}}
             )
           ),
         200 <- response.status,
         %{"name" => version_name} <- response.body,
         {:ok, version} <- parse_version(version_name) do
      {:ok, version}
    else
      _error -> {:error, :credential_store_failed}
    end
  end

  @impl true
  def fetch(%DriverAccount{credential_version: version} = account) when is_integer(version) do
    with {:ok, secret_ref} <- secret_ref(account),
         {:ok, token} <- access_token(),
         {:ok, response} <-
           Req.get(
             request_options(
               url: "#{api_base()}/v1/#{secret_ref}/versions/#{version}:access",
               auth: {:bearer, token}
             )
           ),
         200 <- response.status,
         %{"payload" => %{"data" => encoded}} <- response.body,
         {:ok, auth_json} <- Base.decode64(encoded) do
      {:ok, auth_json}
    else
      _error -> {:error, :credential_not_found}
    end
  end

  def fetch(%DriverAccount{}), do: {:error, :credential_not_found}

  defp access_token do
    with {:ok, response} <-
           Req.get(
             request_options(
               url:
                 "#{metadata_base()}/computeMetadata/v1/instance/service-accounts/default/token",
               headers: [{"metadata-flavor", "Google"}]
             )
           ),
         200 <- response.status,
         %{"access_token" => token} when is_binary(token) <- response.body do
      {:ok, token}
    else
      _error -> {:error, :workload_identity_unavailable}
    end
  end

  defp request_options(options) do
    configured = Keyword.get(config(), :request_options, [])
    Keyword.merge(configured, options)
  end

  defp secret_ref(%DriverAccount{secret_ref: "projects/" <> _rest = ref}), do: {:ok, ref}
  defp secret_ref(%DriverAccount{}), do: {:error, :credential_reference_invalid}

  defp parse_version(name) do
    case Regex.run(~r{/versions/([0-9]+)\z}, name, capture: :all_but_first) do
      [encoded] ->
        case Integer.parse(encoded) do
          {version, ""} when version > 0 -> {:ok, version}
          _invalid -> {:error, :credential_version_invalid}
        end

      _invalid ->
        {:error, :credential_version_invalid}
    end
  end

  defp api_base,
    do: Keyword.get(config(), :secret_manager_api_base, "https://secretmanager.googleapis.com")

  defp metadata_base,
    do: Keyword.get(config(), :metadata_api_base, "http://metadata.google.internal")

  defp config, do: Application.fetch_env!(:openagents, :scv_codex)
end
