defmodule OpenAgents.Forge.RollingProvider.Gcp.Compute do
  @moduledoc """
  Updates one staging instance's immutable image metadata and resets it.

  Requests go directly to the Compute Engine API with a metadata-server token
  or an injected test token. Errors expose only bounded operation and status
  codes. Response bodies and access tokens never enter logs or receipts.
  """

  @api_url "https://compute.googleapis.com/compute/v1"
  @metadata_token_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/
  @instance_pattern ~r/\A[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?\z/

  @doc "Replace one instance's application container with an exact image."
  def replace(instance, sha, digest, config) do
    with :ok <- validate(instance, sha, digest),
         {:ok, token} <- token(config),
         {:ok, metadata} <- instance_metadata(instance, token, config),
         {:ok, operation} <- set_identity(instance, sha, digest, metadata, token, config),
         :ok <- wait_for_operation(operation, token, config),
         {:ok, operation} <- reset(instance, token, config),
         :ok <- wait_for_operation(operation, token, config) do
      :ok
    end
  end

  defp instance_metadata(instance, token, config) do
    case request(:get, instance_url(config, instance), nil, token, config) do
      {:ok, %Req.Response{status: 200, body: %{"metadata" => metadata}}}
      when is_map(metadata) ->
        {:ok, metadata}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:compute_api_error, :get_instance, status}}

      {:error, reason} ->
        {:error, {:compute_transport_error, :get_instance, safe_reason(reason)}}
    end
  end

  defp set_identity(instance, sha, digest, metadata, token, config) do
    with fingerprint when is_binary(fingerprint) <- Map.get(metadata, "fingerprint"),
         items when is_list(items) <- Map.get(metadata, "items", []) do
      identity = %{
        "openagents-image" => Keyword.fetch!(config, :image_repository) <> "@" <> digest,
        "openagents-image-digest" => digest,
        "openagents-sha" => sha
      }

      body = %{
        "fingerprint" => fingerprint,
        "items" => merge_metadata(items, identity)
      }

      operation_request(
        :post,
        instance_url(config, instance) <> "/setMetadata",
        body,
        token,
        config,
        :set_metadata
      )
    else
      _invalid -> {:error, :invalid_instance_metadata}
    end
  end

  defp reset(instance, token, config) do
    operation_request(
      :post,
      instance_url(config, instance) <> "/reset",
      %{},
      token,
      config,
      :reset
    )
  end

  defp operation_request(method, url, body, token, config, action) do
    case request(method, url, body, token, config) do
      {:ok, %Req.Response{status: status, body: %{"name" => name} = operation}}
      when status in 200..299 and is_binary(name) ->
        {:ok, operation}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:compute_api_error, action, status}}

      {:error, reason} ->
        {:error, {:compute_transport_error, action, safe_reason(reason)}}
    end
  end

  defp wait_for_operation(%{"status" => "DONE", "error" => error}, _token, _config)
       when not is_nil(error),
       do: {:error, :compute_operation_failed}

  defp wait_for_operation(%{"status" => "DONE"}, _token, _config), do: :ok

  defp wait_for_operation(%{"name" => name}, token, config) do
    attempts = Keyword.get(config, :operation_attempts, 120)
    do_wait_for_operation(name, token, config, attempts)
  end

  defp wait_for_operation(_operation, _token, _config), do: {:error, :invalid_compute_operation}

  defp do_wait_for_operation(_name, _token, _config, 0),
    do: {:error, :compute_operation_timeout}

  defp do_wait_for_operation(name, token, config, attempts) do
    url =
      api_url(config) <>
        "/projects/#{Keyword.fetch!(config, :project_id)}/zones/" <>
        "#{Keyword.fetch!(config, :zone)}/operations/#{name}"

    case request(:get, url, nil, token, config) do
      {:ok, %Req.Response{status: 200, body: %{"status" => "DONE", "error" => error}}}
      when not is_nil(error) ->
        {:error, :compute_operation_failed}

      {:ok, %Req.Response{status: 200, body: %{"status" => "DONE"}}} ->
        :ok

      {:ok, %Req.Response{status: 200}} ->
        wait(config)
        do_wait_for_operation(name, token, config, attempts - 1)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:compute_api_error, :get_operation, status}}

      {:error, reason} ->
        {:error, {:compute_transport_error, :get_operation, safe_reason(reason)}}
    end
  end

  defp request(method, url, body, token, config) do
    options = [
      method: method,
      url: url,
      headers: [{"authorization", "Bearer " <> token}],
      connect_options: [timeout: 2_000],
      receive_timeout: 10_000,
      retry: false
    ]

    options = if is_nil(body), do: options, else: Keyword.put(options, :json, body)
    Req.request(Keyword.merge(options, Keyword.get(config, :request_options, [])))
  end

  defp token(config) do
    case Keyword.get(config, :token_provider) do
      provider when is_function(provider, 0) -> normalize_token(provider.())
      nil -> metadata_token(config)
      _invalid -> {:error, :invalid_token_provider}
    end
  end

  defp metadata_token(config) do
    options = [
      url: @metadata_token_url,
      headers: [{"metadata-flavor", "Google"}],
      connect_options: [timeout: 2_000],
      receive_timeout: 5_000,
      retry: false
    ]

    case Req.get(Keyword.merge(options, Keyword.get(config, :request_options, []))) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} ->
        normalize_token(token)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:metadata_token_error, status}}

      {:error, reason} ->
        {:error, {:metadata_token_error, safe_reason(reason)}}
    end
  end

  defp normalize_token({:ok, token}), do: normalize_token(token)
  defp normalize_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp normalize_token(_invalid), do: {:error, :invalid_access_token}

  defp merge_metadata(items, identity) do
    retained = Enum.reject(items, &Map.has_key?(identity, Map.get(&1, "key")))
    additions = Enum.map(identity, fn {key, value} -> %{"key" => key, "value" => value} end)
    Enum.sort_by(retained ++ additions, &Map.get(&1, "key", ""))
  end

  defp instance_url(config, instance) do
    api_url(config) <>
      "/projects/#{Keyword.fetch!(config, :project_id)}/zones/" <>
      "#{Keyword.fetch!(config, :zone)}/instances/#{instance}"
  end

  defp api_url(config), do: Keyword.get(config, :api_url, @api_url)

  defp validate(instance, sha, digest) do
    if Regex.match?(@instance_pattern, instance) and Regex.match?(@sha_pattern, sha) and
         Regex.match?(@digest_pattern, digest),
       do: :ok,
       else: {:error, :invalid_replacement_identity}
  end

  defp wait(config) do
    receive do
    after
      Keyword.get(config, :operation_interval_ms, 1_000) -> :ok
    end
  end

  defp safe_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :request_failed
end
