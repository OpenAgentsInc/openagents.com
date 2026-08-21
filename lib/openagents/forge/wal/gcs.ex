defmodule OpenAgents.Forge.WAL.Gcs do
  @moduledoc """
  Google Cloud Storage adapter for `OpenAgents.Forge.WAL` — the production backend.

  Objects live under `forge/wal/<repo>/` in the bucket named by
  `Application.get_env(:openagents, :forge_wal_bucket)`; when the bucket is unset
  every function returns `{:error, :not_configured}` rather than guessing.

  The CAS is GCS's own generation precondition: `cas_index/3` uploads the
  index with `ifGenerationMatch=<generation>` (`0` for `:none`, meaning
  create-only), so GCS itself rejects a stale write with HTTP 412, which maps
  to `{:error, :cas_conflict}`. Entry objects are immutable and keyed by
  sequence plus payload hash, so they need no preconditions.

  Auth: `Application.get_env(:openagents, :forge_gcs_token_provider)` may supply a
  0-arity token function (tests, local credentials); otherwise the adapter
  fetches an access token from the GCE metadata server and caches it in
  `:persistent_term` until shortly before expiry.
  """

  @behaviour OpenAgents.Forge.WAL

  alias OpenAgents.Forge.WAL

  @storage_base "https://storage.googleapis.com"
  @metadata_token_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  @token_cache_key {__MODULE__, :token}
  @token_expiry_margin_seconds 60
  @stream_chunk_bytes 1_048_576
  @default_stream_timeout_ms 6 * 60 * 60 * 1_000

  @impl WAL
  def read_index(repo) do
    with {:ok, bucket} <- bucket() do
      name = index_object(repo)

      with {:ok, generation} <- fetch_generation(bucket, name),
           {:ok, raw} <- download(bucket, name),
           {:ok, index} <- decode_index(raw) do
        {:ok, generation, index}
      end
    end
  end

  @impl WAL
  def cas_index(repo, expected, index) when is_map(index) do
    with {:ok, bucket} <- bucket(),
         {:ok, encoded} <- Jason.encode(index),
         {:ok, token} <- token() do
      generation_match = if expected == :none, do: "0", else: to_string(expected)

      url =
        @storage_base <>
          "/upload/storage/v1/b/#{URI.encode_www_form(bucket)}/o?" <>
          URI.encode_query(
            uploadType: "media",
            name: index_object(repo),
            ifGenerationMatch: generation_match
          )

      case Req.post(url,
             body: encoded,
             headers: auth_headers(token) ++ [{"content-type", "application/json"}]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"generation" => generation}}} ->
          {:ok, generation}

        {:ok, %Req.Response{status: 412}} ->
          {:error, :cas_conflict}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:gcs_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl WAL
  def put_entry(repo, seq, payload) when is_integer(seq) and seq >= 0 and is_binary(payload) do
    with {:ok, bucket} <- bucket(),
         {:ok, token} <- token() do
      key = WAL.entry_key(seq, payload)

      url =
        @storage_base <>
          "/upload/storage/v1/b/#{URI.encode_www_form(bucket)}/o?" <>
          URI.encode_query(uploadType: "media", name: object_name(repo, key))

      case Req.post(url,
             body: payload,
             headers: auth_headers(token) ++ [{"content-type", "application/octet-stream"}]
           ) do
        {:ok, %Req.Response{status: 200}} -> {:ok, key}
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:gcs_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl WAL
  def put_entry_file(repo, seq, path) when is_integer(seq) and seq >= 0 do
    with {:ok, bucket} <- bucket(),
         {:ok, key} <- WAL.entry_key_file(seq, path),
         {:ok, size} <- regular_file_size(path),
         {:ok, token} <- token(),
         :ok <- upload_file(bucket, object_name(repo, key), path, size, token) do
      {:ok, key}
    end
  end

  @impl WAL
  def put_object(repo, object_key, payload) when is_binary(payload) do
    with {:ok, bucket} <- bucket(),
         {:ok, token} <- token() do
      url =
        @storage_base <>
          "/upload/storage/v1/b/#{URI.encode_www_form(bucket)}/o?" <>
          URI.encode_query(uploadType: "media", name: object_name(repo, object_key))

      case Req.post(url,
             body: payload,
             headers: auth_headers(token) ++ [{"content-type", "application/octet-stream"}]
           ) do
        {:ok, %Req.Response{status: 200}} -> {:ok, object_key}
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:gcs_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl WAL
  def get_entry(repo, object_key) when is_binary(object_key) do
    with {:ok, bucket} <- bucket() do
      download(bucket, object_name(repo, object_key))
    end
  end

  @impl WAL
  def get_entry_file(repo, object_key, path) when is_binary(object_key) and is_binary(path) do
    with {:ok, bucket} <- bucket(),
         {:ok, token} <- token() do
      download_file(bucket, object_name(repo, object_key), path, token)
    end
  end

  @impl WAL
  def delete_repo(repo) do
    with {:ok, bucket} <- bucket(),
         {:ok, token} <- token() do
      delete_prefix(bucket, prefix(repo), token)
    end
  end

  ## Object naming (public so it is testable without a live bucket)

  @doc """
  The full GCS object name of the index document for `repo`.
  """
  @spec index_object(WAL.repo()) :: String.t()
  def index_object(repo), do: prefix(repo) <> "index.json"

  @doc """
  The full GCS object name for an object key (e.g. `entries/...`) of `repo`.
  """
  @spec object_name(WAL.repo(), String.t()) :: String.t()
  def object_name(repo, object_key), do: prefix(repo) <> object_key

  @doc """
  The object prefix for `repo`: `forge/wal/<repo>/`.
  """
  @spec prefix(WAL.repo()) :: String.t()
  def prefix(repo), do: "forge/wal/" <> repo <> "/"

  ## Internal

  defp delete_prefix(bucket, object_prefix, token) do
    with {:ok, names} <- list_objects(bucket, object_prefix, token),
         :ok <- delete_objects(bucket, names, token) do
      if names == [], do: :ok, else: delete_prefix(bucket, object_prefix, token)
    end
  end

  defp list_objects(bucket, object_prefix, token) do
    url =
      @storage_base <>
        "/storage/v1/b/#{URI.encode_www_form(bucket)}/o?" <>
        URI.encode_query(prefix: object_prefix, maxResults: 1_000, fields: "items(name)")

    case Req.get(url, headers: auth_headers(token)) do
      {:ok, %Req.Response{status: 200, body: %{"items" => items}}} when is_list(items) ->
        {:ok, Enum.map(items, &Map.fetch!(&1, "name"))}

      {:ok, %Req.Response{status: 200}} ->
        {:ok, []}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:gcs_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_objects(_bucket, [], _token), do: :ok

  defp delete_objects(bucket, names, token) do
    names
    |> Task.async_stream(
      fn name -> delete_object(bucket, name, token) end,
      max_concurrency: 8,
      ordered: false,
      timeout: 60_000
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, reason}}
    end)
  end

  defp delete_object(bucket, name, token) do
    case Req.delete(object_url(bucket, name), headers: auth_headers(token), retry: false) do
      {:ok, %Req.Response{status: status}} when status in [204, 404] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:gcs_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_generation(bucket, name) do
    with {:ok, token} <- token() do
      url = object_url(bucket, name) <> "?" <> URI.encode_query(fields: "generation")

      case Req.get(url, headers: auth_headers(token)) do
        {:ok, %Req.Response{status: 200, body: %{"generation" => generation}}} ->
          {:ok, generation}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :not_found}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:gcs_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp download(bucket, name) do
    with {:ok, token} <- token() do
      url = object_url(bucket, name) <> "?alt=media"

      case Req.get(url, headers: auth_headers(token), decode_body: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
        {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:gcs_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp upload_file(bucket, name, path, size, token) do
    url =
      @storage_base <>
        "/upload/storage/v1/b/#{URI.encode_www_form(bucket)}/o?" <>
        URI.encode_query(uploadType: "media", name: name)

    case Req.post(url,
           body: File.stream!(path, @stream_chunk_bytes, []),
           headers:
             auth_headers(token) ++
               [
                 {"content-type", "application/octet-stream"},
                 {"content-length", Integer.to_string(size)}
               ],
           receive_timeout: stream_timeout_ms(),
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:gcs_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_file(bucket, name, path, token) do
    temporary = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)) do
        case Req.get(object_url(bucket, name) <> "?alt=media",
               headers: auth_headers(token),
               into: File.stream!(temporary, @stream_chunk_bytes, [:write, :binary]),
               decode_body: false,
               receive_timeout: stream_timeout_ms(),
               retry: false
             ) do
          {:ok, %Req.Response{status: 200}} ->
            File.rename(temporary, path)

          {:ok, %Req.Response{status: 404}} ->
            {:error, :not_found}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:gcs_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp regular_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, _not_regular} -> {:error, :invalid_entry_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_timeout_ms do
    Application.get_env(
      :openagents,
      :forge_wal_stream_timeout_ms,
      @default_stream_timeout_ms
    )
  end

  defp object_url(bucket, name) do
    @storage_base <>
      "/storage/v1/b/#{URI.encode_www_form(bucket)}/o/#{URI.encode_www_form(name)}"
  end

  defp decode_index(raw) do
    case Jason.decode(raw) do
      {:ok, index} when is_map(index) -> {:ok, index}
      {:ok, other} -> {:error, {:invalid_index, other}}
      {:error, reason} -> {:error, {:invalid_index, reason}}
    end
  end

  defp bucket do
    case Application.get_env(:openagents, :forge_wal_bucket) do
      bucket when is_binary(bucket) and bucket != "" -> {:ok, bucket}
      _unset -> {:error, :not_configured}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp token do
    case Application.get_env(:openagents, :forge_gcs_token_provider) do
      provider when is_function(provider, 0) -> {:ok, provider.()}
      nil -> metadata_token()
    end
  end

  defp metadata_token do
    now = System.system_time(:second)

    case :persistent_term.get(@token_cache_key, nil) do
      {token, expires_at} when expires_at > now ->
        {:ok, token}

      _missing_or_expired ->
        fetch_metadata_token(now)
    end
  end

  defp fetch_metadata_token(now) do
    request =
      Req.get(@metadata_token_url,
        headers: [{"metadata-flavor", "Google"}],
        connect_options: [timeout: 2_000],
        receive_timeout: 5_000,
        retry: false
      )

    case request do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}} ->
        expires_in = Map.get(body, "expires_in", 300)
        expires_at = now + expires_in - @token_expiry_margin_seconds
        :persistent_term.put(@token_cache_key, {token, expires_at})
        {:ok, token}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:metadata_token_error, status, body}}

      {:error, reason} ->
        {:error, {:metadata_token_error, reason}}
    end
  end
end
