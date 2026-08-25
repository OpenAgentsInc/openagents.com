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

  `providerOptions.gateway.only` pins the provider, because the same slug is
  also served by `google` — the Generative Language endpoint, which is not
  where the credits are. Without the pin a fallback would quietly spend money.

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

  @doc false
  def payload_extra do
    case Application.get_env(:openagents, :vercel_gateway_providers) do
      [_first | _rest] = providers -> %{providerOptions: %{gateway: %{only: providers}}}
      _unset -> %{}
    end
  end
end
