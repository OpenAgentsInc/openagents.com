defmodule OpenAgents.Forge.BuildProtocol do
  @moduledoc """
  Versioned, non-executable JSON contract between the serving release and the
  isolated forge builder.

  Every attempt has a UUID build ID. Queue filenames, request bodies, response
  bodies, and retained output references are all bound to that ID, so a late
  response from an abandoned attempt can never satisfy a later retry.
  """

  alias OpenAgents.Forge.WAL

  @request_schema "openagents.forge.build-request.v1"
  @response_schema "openagents.forge.build-response.v1"
  @max_request_bytes 1_048_576
  @max_response_bytes 65_536
  @max_error_bytes 8_192
  @request_keys ~w(schema build_id repo source_sha target_id repo_url baseline_manifest expires_at)
  @response_keys ~w(schema build_id status artifact_digest artifact_ref output_digest output_ref output_excerpt duration_ms error_code error)
  @statuses ~w(ok error expired)

  @type request :: map()
  @type response :: map()

  @doc "Build a validated request map."
  @spec request!(map()) :: request()
  def request!(attrs) when is_map(attrs) do
    request = %{
      "schema" => @request_schema,
      "build_id" => fetch!(attrs, :build_id),
      "repo" => fetch!(attrs, :repo),
      "source_sha" => fetch!(attrs, :source_sha),
      "target_id" => fetch!(attrs, :target_id),
      "repo_url" => fetch!(attrs, :repo_url),
      "baseline_manifest" => Map.get(attrs, :baseline_manifest),
      "expires_at" => fetch!(attrs, :expires_at)
    }

    case validate_request(request) do
      {:ok, validated} -> validated
      {:error, reason} -> raise ArgumentError, "invalid build request: #{inspect(reason)}"
    end
  end

  @doc "Encode a request in canonical JSON after validating it."
  @spec encode_request(request()) :: {:ok, binary()} | {:error, term()}
  def encode_request(request) do
    with {:ok, request} <- validate_request(request) do
      encoded = canonical_json(request)

      if byte_size(encoded) <= @max_request_bytes,
        do: {:ok, encoded},
        else: {:error, :request_too_large}
    end
  end

  @doc "Decode and strictly validate a request body."
  @spec decode_request(binary()) :: {:ok, request()} | {:error, term()}
  def decode_request(body) when is_binary(body) and byte_size(body) <= @max_request_bytes do
    with {:ok, decoded} <- Jason.decode(body), do: validate_request(decoded)
  end

  def decode_request(body) when is_binary(body), do: {:error, :request_too_large}

  @doc "Encode a strictly validated response in canonical JSON."
  @spec encode_response(response()) :: {:ok, binary()} | {:error, term()}
  def encode_response(response) do
    with {:ok, response} <- validate_response(response) do
      encoded = canonical_json(response)

      if byte_size(encoded) <= @max_response_bytes,
        do: {:ok, encoded},
        else: {:error, :response_too_large}
    end
  end

  @doc "Decode and strictly validate a response body."
  @spec decode_response(binary()) :: {:ok, response()} | {:error, term()}
  def decode_response(body) when is_binary(body) and byte_size(body) <= @max_response_bytes do
    with {:ok, decoded} <- Jason.decode(body), do: validate_response(decoded)
  end

  def decode_response(body) when is_binary(body), do: {:error, :response_too_large}

  @doc "Strictly validate a request map and reject unknown fields."
  @spec validate_request(term()) :: {:ok, request()} | {:error, term()}
  def validate_request(%{} = request) do
    with :ok <- exact_keys(request, @request_keys),
         true <- request["schema"] == @request_schema or {:error, :invalid_schema},
         :ok <- validate_uuid(request["build_id"], :build_id),
         :ok <- WAL.validate_repo(request["repo"]),
         :ok <- validate_sha(request["source_sha"]),
         :ok <- validate_uuid(request["target_id"], :target_id),
         :ok <- validate_repo_url(request["repo_url"]),
         :ok <- validate_baseline(request["baseline_manifest"]),
         :ok <- validate_expiry(request["expires_at"]) do
      {:ok, request}
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_request(_request), do: {:error, :invalid_request}

  @doc "Strictly validate a response map and reject unknown fields."
  @spec validate_response(term()) :: {:ok, response()} | {:error, term()}
  def validate_response(%{} = response) do
    with :ok <- exact_keys(response, @response_keys),
         true <- response["schema"] == @response_schema or {:error, :invalid_schema},
         :ok <- validate_uuid(response["build_id"], :build_id),
         true <- response["status"] in @statuses or {:error, :invalid_status},
         :ok <- validate_response_fields(response) do
      {:ok, response}
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_response(_response), do: {:error, :invalid_response}

  @doc "Create a successful response map."
  def ok_response(build_id, attrs) do
    response_base(build_id, "ok")
    |> Map.merge(%{
      "artifact_digest" => fetch!(attrs, :artifact_digest),
      "artifact_ref" => fetch!(attrs, :artifact_ref),
      "output_digest" => fetch!(attrs, :output_digest),
      "output_ref" => fetch!(attrs, :output_ref),
      "output_excerpt" => Map.get(attrs, :output_excerpt, ""),
      "duration_ms" => fetch!(attrs, :duration_ms)
    })
  end

  @doc "Create an error or expiry response map."
  def error_response(build_id, status, error_code, error, attrs \\ %{})
      when status in ~w(error expired) do
    response_base(build_id, status)
    |> Map.merge(%{
      "output_digest" => Map.get(attrs, :output_digest),
      "output_ref" => Map.get(attrs, :output_ref),
      "output_excerpt" => Map.get(attrs, :output_excerpt, ""),
      "duration_ms" => Map.get(attrs, :duration_ms, 0),
      "error_code" => error_code,
      "error" => String.slice(to_string(error), 0, @max_error_bytes)
    })
  end

  @doc "Write bytes through a same-directory temporary file and atomic rename."
  @spec atomic_write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def atomic_write(path, contents, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o600)
    tmp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    lock = path <> ".publish-lock"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents, [:binary]),
         :ok <- File.chmod(tmp, mode),
         {:ok, lock_io} <- File.open(lock, [:write, :exclusive]) do
      try do
        if File.exists?(path),
          do: {:error, :destination_exists},
          else: File.rename(tmp, path)
      after
        File.close(lock_io)
        File.rm(lock)
      end
    else
      {:error, reason} = error ->
        File.rm(tmp)
        if reason == :eexist, do: {:error, :destination_exists}, else: error
    end
    |> tap(fn _result -> File.rm(tmp) end)
  end

  @doc "Canonical JSON used by signed/digested protocol documents."
  @spec canonical_json(term()) :: binary()
  def canonical_json(term) do
    term
    |> ordered()
    |> Jason.encode!()
  end

  defp response_base(build_id, status) do
    %{
      "schema" => @response_schema,
      "build_id" => build_id,
      "status" => status,
      "artifact_digest" => nil,
      "artifact_ref" => nil,
      "output_digest" => nil,
      "output_ref" => nil,
      "output_excerpt" => "",
      "duration_ms" => 0,
      "error_code" => nil,
      "error" => nil
    }
  end

  defp validate_response_fields(%{"status" => "ok"} = response) do
    with :ok <- validate_digest(response["artifact_digest"]),
         :ok <- validate_ref(response["artifact_ref"], "artifacts/", ".tar"),
         :ok <- validate_optional_digest(response["output_digest"]),
         :ok <- validate_optional_ref(response["output_ref"], "output/", ".log"),
         :ok <- validate_excerpt(response["output_excerpt"]),
         :ok <- validate_duration(response["duration_ms"]),
         true <-
           (is_nil(response["error_code"]) and is_nil(response["error"])) or
             {:error, :unexpected_error_fields} do
      :ok
    end
  end

  defp validate_response_fields(response) do
    with true <-
           (is_nil(response["artifact_digest"]) and is_nil(response["artifact_ref"])) or
             {:error, :unexpected_artifact_fields},
         :ok <- validate_optional_digest(response["output_digest"]),
         :ok <- validate_optional_ref(response["output_ref"], "output/", ".log"),
         :ok <- validate_excerpt(response["output_excerpt"]),
         :ok <- validate_duration(response["duration_ms"]),
         :ok <- validate_error_code(response["error_code"]),
         :ok <- validate_error(response["error"]) do
      :ok
    end
  end

  defp validate_baseline(nil), do: :ok

  defp validate_baseline(%{} = manifest) do
    if byte_size(canonical_json(manifest)) <= @max_request_bytes,
      do: :ok,
      else: {:error, :baseline_too_large}
  rescue
    _error -> {:error, :invalid_baseline}
  end

  defp validate_baseline(_manifest), do: {:error, :invalid_baseline}

  defp validate_repo_url(url) when is_binary(url) and byte_size(url) <= 2_048 do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and String.ends_with?(uri.path || "", ".git") do
      :ok
    else
      {:error, :invalid_repo_url}
    end
  end

  defp validate_repo_url(_url), do: {:error, :invalid_repo_url}

  defp validate_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _other -> {:error, :invalid_expiry}
    end
  end

  defp validate_expiry(_value), do: {:error, :invalid_expiry}

  defp validate_sha(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, value), do: :ok, else: {:error, :invalid_source_sha}
  end

  defp validate_sha(_value), do: {:error, :invalid_source_sha}

  defp validate_uuid(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp validate_uuid(_value, field), do: {:error, {:invalid_uuid, field}}

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, value), do: :ok, else: {:error, :invalid_digest}
  end

  defp validate_digest(_value), do: {:error, :invalid_digest}

  defp validate_optional_digest(nil), do: :ok
  defp validate_optional_digest(value), do: validate_digest(value)

  defp validate_ref(value, prefix, suffix) when is_binary(value) do
    basename = Path.basename(value)

    if value == prefix <> basename and String.ends_with?(basename, suffix) and
         not String.contains?(value, ["..", "\\"]) do
      :ok
    else
      {:error, :invalid_ref}
    end
  end

  defp validate_ref(_value, _prefix, _suffix), do: {:error, :invalid_ref}
  defp validate_optional_ref(nil, _prefix, _suffix), do: :ok
  defp validate_optional_ref(value, prefix, suffix), do: validate_ref(value, prefix, suffix)

  defp validate_duration(value) when is_integer(value) and value >= 0 and value <= 86_400_000,
    do: :ok

  defp validate_duration(_value), do: {:error, :invalid_duration}

  defp validate_error_code(value) when is_binary(value) and byte_size(value) in 1..128 do
    if Regex.match?(~r/^[a-z0-9_]+$/, value), do: :ok, else: {:error, :invalid_error_code}
  end

  defp validate_error_code(_value), do: {:error, :invalid_error_code}

  defp validate_error(value) when is_binary(value) and byte_size(value) <= @max_error_bytes,
    do: :ok

  defp validate_error(_value), do: {:error, :invalid_error}

  defp validate_excerpt(value) when is_binary(value) and byte_size(value) <= @max_error_bytes,
    do: :ok

  defp validate_excerpt(_value), do: {:error, :invalid_output_excerpt}

  defp exact_keys(map, allowed) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(allowed),
      do: :ok,
      else: {:error, :unexpected_fields}
  end

  defp fetch!(map, key), do: Map.fetch!(map, key)

  defp ordered(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
