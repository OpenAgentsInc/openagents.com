defmodule OpenAgents.Chat.Gemini.StreamDecoder do
  @moduledoc """
  Decodes a Gemini `streamGenerateContent?alt=sse` body into Sarah's events.

  Gemini frames differ from the OpenRouter Responses API in three ways this
  module absorbs so nothing downstream has to know which provider answered.

  A Gemini chunk carries whole parts rather than named delta events, and a part
  is reasoning exactly when it says `thought: true`. Both kinds arrive in the
  same `parts` array of the same chunk, so the reasoning and the answer are
  told apart by that flag and by nothing else. A part also carries a
  `thoughtSignature`, which is an opaque replay token rather than text; it is
  not content and is never emitted as one.

  Gemini repeats `usageMetadata` on every chunk, cumulative rather than
  incremental, and omits a count it has not measured yet: the first chunk of a
  stream reports a prompt count and no output count at all. Summing those
  repeats would multiply the turn's tokens by the number of chunks, so a
  reported count replaces the count before it, and a count Gemini never sent
  stays absent rather than becoming a zero the console would show as measured.
  That is the same rule `OpenAgents.Chat.TokenUsage` states for reading counts,
  applied where they are written.

  The stream has no `[DONE]` sentinel. A candidate's `finishReason` is the only
  terminal marker, so a body that stops without one is a truncated stream and
  is reported as one instead of being served as a short answer.
  """

  @maximum_buffer_bytes 262_144
  @maximum_delta_bytes 65_536

  defstruct buffer: "",
            complete?: false,
            model: nil,
            assistant_message_id: nil,
            assistant_content: "",
            reasoning_summary: nil,
            finish_reason: nil,
            usage: %{}

  @type t :: %__MODULE__{}
  @type completion :: map()

  @doc "A decoder for one Gemini stream, carrying the model that was requested."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      model: Keyword.get(options, :model),
      assistant_message_id:
        Keyword.get_lazy(options, :message_id, fn -> "gemini-" <> Ecto.UUID.generate() end)
    }
  end

  @doc """
  Feeds one transport chunk and returns the events it completed.

  A chunk is not a frame. Bytes that do not yet end a frame stay in the buffer,
  so a token split across two TCP reads is decoded once, whole, rather than
  twice in halves or not at all.
  """
  @spec feed(t(), binary()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = String.replace(state.buffer <> chunk, "\r\n", "\n")

    if byte_size(buffer) > @maximum_buffer_bytes do
      {:error, :invalid_response}
    else
      parts = String.split(buffer, "\n\n")
      {frames, [remainder]} = Enum.split(parts, -1)
      decode_frames(%{state | buffer: remainder}, frames)
    end
  end

  @doc """
  The completion for a finished stream, or the reason it cannot be read.

  A stream that never reported a `finishReason` is truncated, not complete.
  """
  @spec finish(t()) :: {:ok, completion()} | {:error, atom()}
  def finish(%__MODULE__{complete?: true} = state), do: completion(state)
  def finish(%__MODULE__{}), do: {:error, :stream_interrupted}

  defp decode_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state, []}, fn frame, {:ok, state, events} ->
      case decode_frame(state, frame) do
        {:ok, state, frame_events} -> {:cont, {:ok, state, events ++ frame_events}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_frame(state, frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))

    case data do
      "" -> {:ok, state, []}
      "[DONE]" -> {:ok, state, []}
      json -> decode_chunk(state, Jason.decode(json))
    end
  end

  defp decode_chunk(_state, {:error, _reason}), do: {:error, :invalid_response}

  defp decode_chunk(_state, {:ok, %{"error" => error}}) when is_map(error),
    do: {:error, provider_error(error)}

  defp decode_chunk(state, {:ok, %{} = chunk}) do
    state = state |> capture_model(chunk["modelVersion"]) |> capture_usage(chunk["usageMetadata"])

    case chunk["candidates"] do
      candidates when is_list(candidates) ->
        Enum.reduce_while(candidates, {:ok, state, []}, fn candidate, {:ok, state, events} ->
          case decode_candidate(state, candidate) do
            {:ok, state, candidate_events} -> {:cont, {:ok, state, events ++ candidate_events}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      # A usage-only or metadata-only chunk carries no candidates at all, and a
      # chunk that carries the key as null is the same thing said differently.
      _absent ->
        {:ok, state, []}
    end
  end

  defp decode_chunk(_state, {:ok, _chunk}), do: {:error, :invalid_response}

  defp decode_candidate(state, %{} = candidate) do
    parts = get_in(candidate, ["content", "parts"]) || []

    case Enum.reduce_while(parts, {:ok, state, []}, &decode_part/2) do
      {:ok, state, events} ->
        {:ok, capture_finish_reason(state, candidate["finishReason"]), events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_candidate(_state, _candidate), do: {:error, :invalid_response}

  # A part with no text is a signature carrier, not content. It is skipped
  # rather than emitted as an empty delta the transcript would render as a gap.
  defp decode_part(%{"text" => text} = part, {:ok, state, events})
       when is_binary(text) and text != "" do
    if byte_size(text) > @maximum_delta_bytes do
      {:halt, {:error, :invalid_response}}
    else
      case part["thought"] do
        true ->
          {:cont,
           {:ok, %{state | reasoning_summary: (state.reasoning_summary || "") <> text},
            events ++ [{:reasoning_delta, text}]}}

        _answer ->
          {:cont,
           {:ok, %{state | assistant_content: state.assistant_content <> text},
            events ++ [{:text_delta, text}]}}
      end
    end
  end

  defp decode_part(part, {:ok, state, events}) when is_map(part),
    do: {:cont, {:ok, state, events}}

  defp decode_part(_part, {:ok, _state, _events}), do: {:halt, {:error, :invalid_response}}

  defp capture_model(state, model) when is_binary(model) and byte_size(model) in 1..256,
    do: %{state | model: model}

  defp capture_model(state, _model), do: state

  defp capture_finish_reason(state, reason) when is_binary(reason) and reason != "",
    do: %{state | complete?: true, finish_reason: reason}

  defp capture_finish_reason(state, _reason), do: state

  # Cumulative, not incremental: the newest report of a count replaces the one
  # before it, and a count this chunk did not carry keeps the last one that did.
  defp capture_usage(state, %{} = usage) do
    counts =
      %{
        "input_tokens" => count(usage["promptTokenCount"]),
        "output_tokens" => count(usage["candidatesTokenCount"]),
        "total_tokens" => count(usage["totalTokenCount"]),
        "reasoning_tokens" => count(usage["thoughtsTokenCount"]),
        "cached_tokens" => count(usage["cachedContentTokenCount"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{state | usage: Map.merge(state.usage, counts)}
  end

  defp capture_usage(state, _usage), do: state

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp completion(%__MODULE__{model: model, assistant_message_id: id})
       when not is_binary(model) or not is_binary(id) do
    {:error, :invalid_response}
  end

  # A turn that produced neither an answer nor reasoning read nothing back, so
  # there is no transcript to store. A turn that spent its whole budget
  # thinking answers with empty content and its reasoning intact, because that
  # is what happened, and `finish_reason` says so.
  defp completion(%__MODULE__{assistant_content: "", reasoning_summary: summary})
       when summary in [nil, ""] do
    {:error, :invalid_response}
  end

  defp completion(%__MODULE__{} = state) do
    completion =
      %{
        "object" => "response",
        "model" => state.model,
        "assistant_message_id" => state.assistant_message_id,
        "assistant_content" => state.assistant_content,
        "finish_reason" => state.finish_reason
      }
      |> put_reasoning_summary(state.reasoning_summary)
      |> put_usage(state.usage)

    {:ok, completion}
  end

  defp put_reasoning_summary(completion, summary) when is_binary(summary) and summary != "",
    do: Map.put(completion, "reasoning_summary", summary)

  defp put_reasoning_summary(completion, _summary), do: completion

  # Translated into the names the turn already stores, so one reader maps every
  # provider's counts and Gemini needs no branch of its own downstream.
  defp put_usage(completion, usage) when map_size(usage) == 0, do: completion

  defp put_usage(completion, usage) do
    reported =
      %{
        "input_tokens" => usage["input_tokens"],
        "output_tokens" => usage["output_tokens"],
        "total_tokens" => usage["total_tokens"],
        "output_tokens_details" => details("reasoning_tokens", usage["reasoning_tokens"]),
        "input_tokens_details" => details("cached_tokens", usage["cached_tokens"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.put(completion, "usage", reported)
  end

  defp details(_field, nil), do: nil
  defp details(field, value), do: %{field => value}

  defp provider_error(%{"status" => status} = error) when is_binary(status),
    do: normalize_status(status, error["code"])

  defp provider_error(%{"code" => code}) when is_integer(code), do: normalize_code(code)
  defp provider_error(_error), do: :provider_unavailable

  defp normalize_status("RESOURCE_EXHAUSTED", _code), do: :rate_limited
  defp normalize_status("UNAVAILABLE", _code), do: :service_unavailable
  defp normalize_status("DEADLINE_EXCEEDED", _code), do: :service_unavailable
  defp normalize_status(_status, code) when is_integer(code), do: normalize_code(code)
  defp normalize_status(_status, _code), do: :provider_unavailable

  defp normalize_code(429), do: :rate_limited
  defp normalize_code(code) when code in [500, 502, 503, 504], do: :service_unavailable
  defp normalize_code(_code), do: :provider_unavailable
end
