defmodule OpenAgents.Providers.VercelGateway do
  @moduledoc """
  Vercel AI Gateway adapter: one endpoint in front of many providers.

  This is how Gemini reaches Google's own hardware, and the reason it exists is
  money. The credits this account holds are Google's, so a Gemini call has to
  land on Vertex to spend them. Two routes reach Vertex:

  1. Directly, with a Google identity. That was written and it worked, and it
     cost an OAuth token minter, a service-account JWT signer, a project-scoped
     `locations/global` path, and a workaround for Gemini 3 refusing any
     transcript whose `functionCall` parts do not carry back the
     `thoughtSignature` it produced — a 400, not a warning, with nowhere in an
     OpenAI-shaped transcript to put a 360-character signature.
  2. Through this gateway, which is OpenAI chat completions — the shape the
     OpenRouter adapter already speaks — and which does that translation
     itself.

  The gateway's own reply settles it. With BYOK Vertex credentials configured
  it answers `"credentialType":"byok"`, `"resolvedProvider":"vertex"`, and
  `"cost":"0"`: the call ran on Google's hardware against the credits, and the
  gateway charged nothing to put it there.

  `providerOptions.gateway.order` tries Vertex first, because the same slug is
  also served by `google` — the Generative Language endpoint, which is not
  where the credits are. `providerOptions.gateway.models` lists the fallback
  models Vercel tries if the primary model fails.

  That list is why this lane reports `substitutable?/0` as true: a call for
  `google/gemini-3.7-flash` can be answered by `zai/glm-5.3` and still return
  200, so the model that was asked for is not evidence of the model that
  answered. The response's `model` field is, and the chat-completions decoder
  reads it back as `{:model_served, name}` so the call is priced and attributed
  against the lane that served it rather than the lane that was requested
  (METER-001, PROVIDER-002).

  The wire format is OpenRouter's, so the request building and the stream
  decoding are OpenRouter's too. What differs is the endpoint, the credential,
  and the pin.
  """

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.{OpenRouter, Request}

  @endpoint "https://ai-gateway.vercel.sh/v1/chat/completions"

  @impl true
  def id, do: "vercel_gateway.chat_completions"

  @impl true
  def capabilities, do: [:text, :tool_calls, :usage]

  @impl true
  def configured? do
    match?({:ok, _key}, OpenAgents.RuntimeConfig.fetch_secret(:vercel_gateway_api_key))
  end

  @doc """
  Whether a call on this lane may be answered by a different model.

  True exactly while a fallback list is configured. `providerOptions.gateway.models`
  is an instruction to Vercel to try another model when the primary fails, so a
  request for `google/gemini-3.7-flash` can be answered by `zai/glm-5.3` and
  return 200. The host reads the serving model back off the response; this
  says what its silence means, because a lane that cannot be substituted for
  needs no disclosure to be attributed correctly.
  """
  @impl true
  def substitutable?, do: fallback_models() != []

  @impl true
  def stream(%Request{} = request, on_event) when is_function(on_event, 1) do
    stream(request, on_event, [])
  end

  @doc false
  def stream(%Request{} = request, on_event, options)
      when is_function(on_event, 1) and is_list(options) do
    with {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- OpenRouter.post(api_key, request, gateway_options(options)) do
      OpenRouter.consume(response, on_event)
    end
  end

  defp fetch_api_key(options) do
    case Keyword.fetch(options, :api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _not_supplied ->
        case OpenAgents.RuntimeConfig.fetch_secret(:vercel_gateway_api_key) do
          {:ok, key} -> {:ok, key}
          {:error, :not_configured} -> {:error, :missing_api_key}
        end
    end
  end

  defp gateway_options(options) do
    options
    |> Keyword.put(:endpoint, @endpoint)
    |> Keyword.put(:payload_extra, payload_extra())
  end

  @doc "The models Vercel may try when the requested one fails."
  @spec fallback_models() :: [String.t()]
  def fallback_models do
    case Application.get_env(:openagents, :vercel_gateway_fallback_models, []) do
      models when is_list(models) -> models
      _not_a_list -> []
    end
  end

  @doc false
  def payload_extra do
    providers = Application.get_env(:openagents, :vercel_gateway_providers, [])
    fallbacks = fallback_models()

    gateway =
      %{}
      |> maybe_put(:order, providers)
      |> maybe_put(:models, fallbacks)

    if map_size(gateway) > 0 do
      %{providerOptions: %{gateway: gateway}}
    else
      %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, [_ | _] = values), do: Map.put(map, key, values)
end
