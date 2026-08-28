defmodule OpenAgents.Inference.CoderApiHop do
  @moduledoc """
  Reverse-proxy an already-admitted inference call to the rust coder API.

  Phoenix keeps grant auth, credit, and metering. The rust process runs the
  catalog, simple-flash classifier, and pinned provider stream.
  """

  require Logger

  @doc "Configured rust origin and shared internal token, or `:local`."
  @spec target() :: {:ok, String.t(), String.t()} | :local
  def target do
    origin = Application.get_env(:openagents, :coder_api_origin)
    token = Application.get_env(:openagents, :coder_api_internal_token)

    if present?(origin) and present?(token) do
      {:ok, String.trim_trailing(origin, "/"), token}
    else
      :local
    end
  end

  @doc "POST the OpenAI body to rust and return status, headers, and SSE body."
  @spec post(String.t(), String.t(), String.t(), map()) ::
          {:ok, pos_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def post(origin, internal_token, admitted_model, body) when is_map(body) do
    url = origin <> "/api/inference/proxy"

    case Req.post(url,
           json: body,
           headers: [
             {"authorization", "Bearer " <> internal_token},
             {"x-openagents-admitted-model", admitted_model},
             {"accept", "text/event-stream"}
           ],
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body_to_binary(body)}

      {:error, reason} ->
        Logger.warning("coder_api_hop_failed reason=#{inspect(reason, limit: 80)}")
        {:error, reason}
    end
  end

  @doc "OpenAI `usage` object → Phoenix grant usage keys."
  @spec usage_from_sse(binary()) :: map()
  def usage_from_sse(body) when is_binary(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.reduce(%{}, fn frame, acc ->
      payload = String.replace_prefix(frame, "data: ", "")

      case Jason.decode(payload) do
        {:ok, %{"usage" => usage}} when is_map(usage) -> openai_usage(usage)
        _ -> acc
      end
    end)
  end

  def usage_from_sse(_), do: %{}

  @doc "Header value rust attributes as the served model."
  @spec served_model(term()) :: String.t() | nil
  def served_model(headers) when is_map(headers) do
    case Map.get(headers, "x-openagents-model") do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def served_model(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == "x-openagents-model" do
          header_value(value)
        end

      _ ->
        nil
    end)
  end

  def served_model(_), do: nil

  defp openai_usage(usage) do
    input = integer(usage["prompt_tokens"] || usage["input_tokens"])
    output = integer(usage["completion_tokens"] || usage["output_tokens"])
    total = integer(usage["total_tokens"])

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => if(total > 0, do: total, else: input + output)
    }
    |> Enum.reject(fn {_k, v} -> v == 0 end)
    |> Map.new()
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(%Req.Response.Async{} = async), do: Enum.into(async, "")
  defp body_to_binary(_), do: ""

  defp header_value([value | _]) when is_binary(value), do: value
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_), do: 0
end
