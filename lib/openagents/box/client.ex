defmodule OpenAgents.Box.Client do
  @moduledoc """
  Typed `Req` client for the Box Public API v1 at `ascii.dev`.

  Every function returns `{:ok, body}` for a `2xx` response and a typed
  `{:error, reason}` otherwise. The bearer key comes from the `:box_api_key`
  application setting; an absent key fails closed with `:box_not_configured`
  before any request leaves the host. Desktop and viewer URLs never pass
  through this module: no function requests them, so a token-bearing URL
  cannot reach a caller or a log.
  """

  @default_base_url "https://ascii.dev/api/box/v1"

  @box_id_pattern ~r/^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$/

  @type body :: map()

  @doc "Provisions a new box. The idempotency key makes a retried create safe."
  @spec create_box(map(), String.t()) :: {:ok, body()} | {:error, term()}
  def create_box(attributes, idempotency_key)
      when is_map(attributes) and is_binary(idempotency_key) do
    request(:post, "/boxes", json: attributes, headers: [{"idempotency-key", idempotency_key}])
  end

  @doc "Reads one box's current state and setup status."
  @spec get_box(String.t()) :: {:ok, body()} | {:error, term()}
  def get_box(box_id) when is_binary(box_id) do
    with :ok <- validate_box_id(box_id), do: request(:get, "/boxes/#{box_id}", [])
  end

  @doc "Stops and archives a box; a snapshot remains available for resume."
  @spec stop_box(String.t()) :: {:ok, body()} | {:error, term()}
  def stop_box(box_id) when is_binary(box_id) do
    with :ok <- validate_box_id(box_id), do: request(:post, "/boxes/#{box_id}/stop", [])
  end

  @doc "Runs one shell command on a box and returns its captured result."
  @spec command(String.t(), map()) :: {:ok, body()} | {:error, term()}
  def command(box_id, attributes) when is_binary(box_id) and is_map(attributes) do
    with :ok <- validate_box_id(box_id) do
      request(:post, "/boxes/#{box_id}/commands", json: attributes)
    end
  end

  @doc "Whether a string is a well-formed box id."
  @spec valid_box_id?(String.t()) :: boolean()
  def valid_box_id?(box_id) when is_binary(box_id), do: Regex.match?(@box_id_pattern, box_id)
  def valid_box_id?(_box_id), do: false

  defp validate_box_id(box_id) do
    if valid_box_id?(box_id), do: :ok, else: {:error, :box_not_found}
  end

  defp request(method, api_path, options) do
    with {:ok, api_key} <- api_key() do
      settings = Application.get_env(:openagents, :box_api, [])
      base_url = settings[:base_url] || @default_base_url

      request_options =
        options
        |> Keyword.put(:receive_timeout, settings[:receive_timeout_ms] || 630_000)
        |> Keyword.merge(settings[:request_options] || [])
        |> Keyword.put(:auth, {:bearer, api_key})
        |> Keyword.put_new(:retry, retry_policy(method))
        |> Keyword.put_new(:max_retries, 2)
        |> Keyword.put_new(:retry_log_level, false)

      case Req.request([method: method, url: base_url <> api_path] ++ request_options) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:error, :box_response_invalid}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :box_unauthorized}

        {:ok, %Req.Response{status: status}} when status in [402, 403] ->
          {:error, :box_billing_required}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :box_not_found}

        {:ok, %Req.Response{status: 429}} ->
          {:error, :box_rate_limited}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:box_request_refused, status, error_code(body)}}

        {:error, _transport} ->
          {:error, :box_unreachable}
      end
    end
  end

  # Reads retry transparently; a command is not replayed because a timed-out
  # command may still be running on the box.
  defp retry_policy(:get), do: :safe_transient
  defp retry_policy(_method), do: false

  defp api_key do
    case Application.fetch_env(:openagents, :box_api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _missing -> {:error, :box_not_configured}
    end
  end

  defp error_code(%{"code" => code}) when is_binary(code), do: code
  defp error_code(_body), do: "unknown"
end
