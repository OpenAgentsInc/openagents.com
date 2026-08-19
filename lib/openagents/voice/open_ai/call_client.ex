defmodule OpenAgents.Voice.OpenAI.CallClient do
  @moduledoc """
  OpenAI unified Realtime call adapter.

  Standard credentials and protected session configuration terminate here.
  The browser receives only the SDP answer.
  """

  @behaviour OpenAgents.Voice.CallProvider

  alias OpenAgents.Voice.{CallAdmission, Config}

  @endpoint "https://api.openai.com/v1/realtime/calls"
  @maximum_sdp_bytes 65_536

  @impl true
  def create(sdp_offer, safety_identifier, %Config{} = config) do
    create(sdp_offer, safety_identifier, config, [])
  end

  @doc false
  def create(sdp_offer, safety_identifier, %Config{} = config, options)
      when is_list(options) do
    with :ok <- validate_enabled(config),
         :ok <- validate_sdp(sdp_offer),
         :ok <- validate_safety_identifier(safety_identifier),
         {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- request(sdp_offer, safety_identifier, config, api_key, options) do
      decode_response(response)
    end
  end

  defp validate_enabled(%Config{enabled?: true}), do: :ok
  defp validate_enabled(%Config{}), do: {:error, :voice_disabled}

  defp validate_sdp("v=0" <> _rest = sdp) when byte_size(sdp) <= @maximum_sdp_bytes, do: :ok
  defp validate_sdp(_sdp), do: {:error, :invalid_sdp}

  defp validate_safety_identifier(identifier)
       when is_binary(identifier) and byte_size(identifier) == 64,
       do: :ok

  defp validate_safety_identifier(_identifier), do: {:error, :invalid_safety_identifier}

  defp fetch_api_key(options) do
    case Keyword.get(options, :api_key) || System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp request(sdp_offer, safety_identifier, config, api_key, options) do
    request_options = Keyword.get(options, :request_options, [])

    base_options = [
      auth: {:bearer, api_key},
      headers: [
        {"accept", "application/sdp"},
        {"openai-safety-identifier", safety_identifier}
      ],
      form_multipart: [
        sdp: sdp_offer,
        session: Jason.encode!(Config.session_payload(config))
      ],
      receive_timeout: 30_000,
      retry: :transient,
      max_retries: 1,
      decode_body: false
    ]

    case Req.post(@endpoint, Keyword.merge(base_options, request_options)) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        {:error, {:transport, reason}}

      {:error, _error} ->
        {:error, {:transport, :request_failed}}
    end
  end

  defp decode_response(%Req.Response{status: status, body: answer_sdp} = response)
       when status in 200..299 and is_binary(answer_sdp) do
    with :ok <- validate_answer_sdp(answer_sdp),
         {:ok, call_id} <- call_id(response) do
      {:ok, %CallAdmission{provider_session_id: call_id, answer_sdp: answer_sdp}}
    end
  end

  defp decode_response(%Req.Response{status: status}) when status in 400..599,
    do: {:error, {:http_status, status}}

  defp decode_response(%Req.Response{}), do: {:error, :invalid_provider_response}

  defp validate_answer_sdp("v=0" <> _rest = sdp) when byte_size(sdp) <= @maximum_sdp_bytes,
    do: :ok

  defp validate_answer_sdp(_sdp), do: {:error, :invalid_provider_response}

  defp call_id(response) do
    case Req.Response.get_header(response, "location") do
      [location] -> parse_call_location(location)
      _missing_or_repeated -> {:error, :missing_call_id}
    end
  end

  defp parse_call_location(location) when is_binary(location) do
    case String.split(location, "/", trim: true) do
      ["v1", "realtime", "calls", "rtc_" <> _rest = call_id]
      when byte_size(call_id) <= 256 ->
        {:ok, call_id}

      _invalid ->
        {:error, :invalid_call_id}
    end
  end
end
