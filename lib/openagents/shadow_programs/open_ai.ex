defmodule OpenAgents.ShadowPrograms.OpenAI do
  @moduledoc "OpenResponses 2026-04-24 structured-output adapter for shadow programs."

  @behaviour OpenAgents.ShadowPrograms.Provider

  @endpoint "https://api.openai.com/v1/responses"
  @maximum_response_bytes 65_536

  def id, do: "openai.responses.shadow"

  @impl true
  def evaluate(artifact, signature, input, timeout_ms) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response} <- post(api_key, request_payload(artifact, signature, input), timeout_ms),
         {:ok, output} <- extract_output(response.body) do
      {:ok,
       %{
         output: output,
         response_id: response.body["id"],
         usage: normalize_usage(response.body["usage"])
       }}
    end
  end

  @doc false
  def request_payload(artifact, signature, input) do
    prompt =
      artifact.document["prompt_ir"]["blocks"]
      |> Enum.map_join("\n\n", & &1["content"])

    %{
      model: artifact.document["model"]["model"],
      instructions: prompt,
      input: [%{role: "user", content: Jason.encode!(input)}],
      text: %{
        format: %{
          type: "json_schema",
          name: schema_name(signature.id),
          strict: true,
          schema: signature.output_schema
        }
      },
      max_output_tokens: artifact.document["decoding"]["max_output_tokens"],
      store: false,
      stream: false
    }
  end

  defp fetch_api_key do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp post(api_key, payload, timeout_ms) do
    case Req.post(@endpoint,
           auth: {:bearer, api_key},
           json: payload,
           receive_timeout: timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timed_out}
      {:error, _error} -> {:error, :provider_failed}
    end
  end

  defp extract_output(%{"id" => id, "output" => output})
       when is_binary(id) and is_list(output) do
    texts =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text", "text" => text} <- content,
          is_binary(text),
          do: text

    case texts do
      [text] when byte_size(text) <= @maximum_response_bytes ->
        case Jason.decode(text) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _invalid -> {:error, :malformed_output}
        end

      _invalid ->
        {:error, :malformed_output}
    end
  end

  defp extract_output(_body), do: {:error, :malformed_response}

  defp normalize_usage(usage) when is_map(usage) do
    usage
    |> Map.take(~w(input_tokens output_tokens total_tokens))
    |> Enum.filter(fn {_key, value} -> is_integer(value) and value >= 0 end)
    |> Map.new()
  end

  defp normalize_usage(_usage), do: %{}

  defp schema_name(signature_id), do: String.replace(signature_id, ~r/[^a-zA-Z0-9_-]/, "_")
end
