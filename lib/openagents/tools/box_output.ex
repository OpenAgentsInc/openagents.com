defmodule OpenAgents.Tools.BoxOutput do
  @moduledoc "Bounds and redacts output returned by Box commands."

  alias OpenAgents.Tools.Redaction

  @maximum_stream_bytes 24 * 1_024
  @credential_url_pattern ~r{https?://[^\s/@:]+:[^\s/@]+@[^\s]+}i
  @token_query_url_pattern ~r{https?://[^\s]+[?&](?:access[_-]?token|token|api[_-]?key|auth(?:entication)?[_-]?token|secret|credential)=[^\s&#]+[^\s]*}i
  @provider_url_pattern ~r{https?://(?:desktop|viewer)\.ascii\.dev[^\s]*}i

  @spec bounded(term()) :: {String.t(), boolean()}
  def bounded(nil), do: {"", false}

  def bounded(stream) when is_binary(stream) do
    redacted =
      stream
      |> scrub()
      |> Redaction.redact_text()
      |> redact_credential_urls()

    if byte_size(redacted) <= @maximum_stream_bytes do
      {redacted, false}
    else
      {tail_bytes(redacted, @maximum_stream_bytes), true}
    end
  end

  def bounded(_other), do: {"", false}

  defp redact_credential_urls(text) do
    text =
      Regex.replace(@credential_url_pattern, text, "[REDACTED_URL]")

    text =
      Regex.replace(@token_query_url_pattern, text, "[REDACTED_URL]")

    Regex.replace(@provider_url_pattern, text, "[REDACTED_URL]")
  end

  defp scrub(output) do
    if String.valid?(output) do
      output
    else
      output
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk -> if String.valid?(chunk), do: chunk, else: "\uFFFD" end)
    end
  end

  defp tail_bytes(text, limit) do
    text
    |> binary_part(byte_size(text) - limit, limit)
    |> trim_partial_prefix(3)
  end

  defp trim_partial_prefix(text, 0), do: text

  defp trim_partial_prefix(text, attempts) do
    case text do
      <<_first, rest::binary>> ->
        if String.valid?(text), do: text, else: trim_partial_prefix(rest, attempts - 1)

      _empty ->
        text
    end
  end
end
