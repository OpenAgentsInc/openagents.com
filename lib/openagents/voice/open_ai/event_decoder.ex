defmodule OpenAgents.Voice.OpenAI.EventDecoder do
  @moduledoc "Decodes OpenAI Realtime wire events into bounded Sarah voice events."

  alias OpenAgents.Voice.ProviderEvent
  alias OpenAgents.Voice.Usage

  @maximum_identifier_bytes 512
  @maximum_transcript_bytes 16_000
  @maximum_tool_arguments_bytes 16_000

  @spec decode(map()) :: {:ok, ProviderEvent.t()} | :ignore | {:error, atom()}
  def decode(%{"type" => type} = event) when is_binary(type) do
    with {:ok, provider_event_id} <- optional_identifier(event["event_id"], 256) do
      decode_type(type, event, provider_event_id)
    end
  end

  def decode(_event), do: {:error, :invalid_provider_event}

  defp decode_type("session.created", _event, event_id),
    do: ok(:session_created, event_id, %{})

  defp decode_type("session.updated", _event, event_id),
    do: ok(:session_ready, event_id, %{})

  defp decode_type("input_audio_buffer.speech_started", event, event_id) do
    ok(:speech_started, event_id, optional_payload(event, ["item_id"]))
  end

  defp decode_type("input_audio_buffer.speech_stopped", event, event_id) do
    ok(:speech_stopped, event_id, optional_payload(event, ["item_id"]))
  end

  defp decode_type("response.created", event, event_id) do
    with {:ok, response_id} <- required_identifier(get_in(event, ["response", "id"])) do
      ok(:response_started, event_id, %{"response_id" => response_id})
    end
  end

  defp decode_type("conversation.item.input_audio_transcription.completed", event, event_id) do
    transcript_event(:user_transcript_final, event, event_id, :optional_response)
  end

  defp decode_type("conversation.item.input_audio_transcription.delta", event, event_id) do
    transcript_delta_event(:user_transcript_delta, event, event_id)
  end

  defp decode_type("response.output_audio_transcript.delta", event, event_id) do
    transcript_delta_event(:assistant_transcript_delta, event, event_id)
  end

  defp decode_type("response.output_audio_transcript.done", event, event_id) do
    transcript_event(:assistant_transcript_final, event, event_id, :required_response)
  end

  # Text-only responses (for example the host-authored compaction response,
  # which sets output_modalities: ["text"]) finalize output as text rather
  # than an audio transcript. The final text is the same durable assistant
  # evidence class as a spoken transcript.
  defp decode_type("response.output_text.done", event, event_id) do
    transcript_event(:assistant_transcript_final, event, event_id, :required_response)
  end

  defp decode_type("response.function_call_arguments.done", event, event_id) do
    with {:ok, response_id} <- required_identifier(event["response_id"]),
         {:ok, item_id} <- required_identifier(event["item_id"]),
         {:ok, call_id} <- required_identifier(event["call_id"]),
         {:ok, tool_name} <- bounded_string(event["name"], 128),
         {:ok, raw_arguments} <-
           bounded_string(event["arguments"], @maximum_tool_arguments_bytes) do
      ok(:tool_call_requested, event_id, %{
        "response_id" => response_id,
        "item_id" => item_id,
        "call_id" => call_id,
        "tool_name" => tool_name,
        "raw_arguments" => raw_arguments
      })
    end
  end

  defp decode_type("response.done", event, event_id) do
    response = Map.get(event, "response", %{})

    with {:ok, response_id} <- required_identifier(response["id"]),
         {:ok, status} <- bounded_string(response["status"] || "unknown", 64) do
      ok(:response_completed, event_id, %{
        "response_id" => response_id,
        "status" => status,
        "usage" => Usage.normalize_provider(response["usage"])
      })
    end
  end

  # `response_cancel_not_active` means a cancel raced with a response that had
  # already finished; the session remains healthy.
  defp decode_type("error", event, event_id) do
    error = Map.get(event, "error", %{})

    case normalize_error_code(error["code"] || error["type"]) do
      "response_cancel_not_active" -> :ignore
      code -> ok(:provider_error, event_id, %{"code" => code})
    end
  end

  defp decode_type(_unknown, _event, _event_id), do: :ignore

  # Final transcripts are non-critical UI/audible projections. Malformed or
  # empty ones (for example blank gpt-4o-mini-transcribe noise output) are
  # dropped rather than treated as fatal protocol errors.
  defp transcript_event(kind, event, event_id, response_requirement) do
    transcript = event["transcript"] || event["text"]

    with {:ok, item_id} <- required_identifier(event["item_id"]),
         {:ok, content} <-
           transcript_content_or_ignore(transcript, @maximum_transcript_bytes),
         true <- not is_nil(content),
         {:ok, response_id} <-
           transcript_response_id(event["response_id"], response_requirement) do
      ok(kind, event_id, %{
        "item_id" => item_id,
        "response_id" => response_id,
        "content" => content
      })
    else
      _error -> :ignore
    end
  end

  # Deltas are ephemeral projections; malformed ones are dropped rather than
  # treated as protocol failures.
  defp transcript_delta_event(kind, event, event_id) do
    with {:ok, item_id} <- required_identifier(event["item_id"]),
         {:ok, delta} <- bounded_string(event["delta"], @maximum_transcript_bytes) do
      ok(kind, event_id, %{"item_id" => item_id, "delta" => delta})
    else
      {:error, _reason} -> :ignore
    end
  end

  defp ok(kind, event_id, payload),
    do: {:ok, %ProviderEvent{kind: kind, provider_event_id: event_id, payload: payload}}

  defp transcript_content_or_ignore(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: {:ok, value}

  defp transcript_content_or_ignore(_value, _maximum), do: {:ok, nil}

  defp required_identifier(value), do: bounded_string(value, @maximum_identifier_bytes)

  defp optional_identifier(nil, _maximum), do: {:ok, nil}
  defp optional_identifier(value, maximum), do: bounded_string(value, maximum)

  defp transcript_response_id(value, :required_response), do: required_identifier(value)

  defp transcript_response_id(value, :optional_response),
    do: optional_identifier(value, @maximum_identifier_bytes)

  defp bounded_string(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: {:ok, value}

  defp bounded_string(_value, _maximum), do: {:error, :invalid_provider_event}

  defp optional_payload(event, keys) do
    Map.new(keys, fn key -> {key, optional_value(event[key])} end)
  end

  defp optional_value(value) when is_binary(value) and byte_size(value) <= 512, do: value
  defp optional_value(_value), do: nil

  defp normalize_error_code(code) when is_binary(code) do
    code
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
    |> String.slice(0, 128)
    |> case do
      "" -> "provider_error"
      normalized -> normalized
    end
  end

  defp normalize_error_code(_code), do: "provider_error"
end
