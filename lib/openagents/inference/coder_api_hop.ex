defmodule OpenAgents.Inference.CoderApiHop do
  @moduledoc """
  Reverse-proxy an already-admitted inference call to the rust coder API.

  Phoenix keeps grant auth, credit, and metering. The rust process runs the
  catalog, simple-flash classifier, and pinned provider stream.

  The hop POST uses `into: :self` so response headers return before the SSE
  body finishes. Callers write each chunk as it arrives; collecting a copy
  for `usage_from_sse/1` is fine as long as the client sees bytes first.
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

  @doc """
  POST the OpenAI body to rust and return status, headers, and the SSE body.

  The body is a `Req.Response.Async` when rust answers with a stream: headers
  are available before the last frame. Consume it with `reduce_chunks/3` so
  the client sees bytes as they arrive.
  """
  @spec post(String.t(), String.t(), String.t(), map()) ::
          {:ok, pos_integer(), term(), binary() | Req.Response.Async.t()} | {:error, term()}
  def post(origin, internal_token, admitted_model, body) when is_map(body) do
    url = origin <> "/api/inference/proxy"

    case Req.post(url,
           json: body,
           headers: [
             {"authorization", "Bearer " <> internal_token},
             {"x-openagents-admitted-model", admitted_model},
             {"accept", "text/event-stream"}
           ],
           into: :self,
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body}

      {:error, reason} ->
        Logger.warning("coder_api_hop_failed reason=#{inspect(reason, limit: 80)}")
        {:error, reason}
    end
  end

  @doc "Fold each SSE chunk as it arrives. Binary bodies yield once."
  @spec reduce_chunks(binary() | Req.Response.Async.t() | term(), acc, (binary(), acc -> acc)) ::
          acc
        when acc: var
  def reduce_chunks(%Req.Response.Async{} = async, acc, fun) when is_function(fun, 2) do
    Enum.reduce(async, acc, fn chunk, acc -> fun.(chunk_binary(chunk), acc) end)
  end

  def reduce_chunks(body, acc, fun) when is_binary(body) and is_function(fun, 2) do
    fun.(body, acc)
  end

  def reduce_chunks(_body, acc, fun) when is_function(fun, 2), do: acc

  @doc "Drain a hop body that will not be forwarded."
  @spec discard(term()) :: :ok
  def discard(%Req.Response.Async{} = async) do
    Enum.each(async, fn _chunk -> :ok end)
    :ok
  rescue
    _exception -> :ok
  end

  def discard(_body), do: :ok

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

  defp chunk_binary(chunk) when is_binary(chunk), do: chunk
  defp chunk_binary(chunk), do: IO.iodata_to_binary(List.wrap(chunk))

  defp header_value([value | _]) when is_binary(value), do: value
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_), do: 0
end
