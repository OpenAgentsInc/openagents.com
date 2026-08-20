defmodule OpenAgents.SCV.OpenCodeReport do
  @moduledoc """
  Collects a bounded prose report from OpenCode text events.

  The executor feeds this module only lines that have already passed through
  its run-specific redaction boundary. Tool output and diagnostic lines never
  enter the report.
  """

  @maximum_bytes 32_768

  @type t :: %{
          text: String.t(),
          bytes: non_neg_integer(),
          truncated?: boolean()
        }

  @spec new() :: t()
  def new do
    %{text: "", bytes: 0, truncated?: false}
  end

  @spec ingest(t(), binary()) :: t()
  def ingest(%{truncated?: true} = state, _line), do: state

  def ingest(state, line) when is_map(state) and is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "text", "part" => %{"text" => text}}} when is_binary(text) ->
        append(state, text)

      _other ->
        state
    end
  end

  @spec summary(t()) :: map()
  def summary(state) when is_map(state) do
    %{
      schema: "openagents.scv.report.v1",
      text: state.text,
      bytes: state.bytes,
      truncated: state.truncated?
    }
  end

  @doc "Splits a report into UTF-8-safe chunks for structured log delivery."
  @spec chunks(map(), pos_integer()) :: [String.t()]
  def chunks(%{text: text}, maximum_bytes)
      when is_binary(text) and is_integer(maximum_bytes) and maximum_bytes >= 4 do
    split_chunks(text, maximum_bytes, [])
  end

  defp append(state, ""), do: state

  defp append(state, text) do
    separator = if state.text == "", do: "", else: "\n"
    addition = separator <> text
    available = max(@maximum_bytes - state.bytes, 0)
    captured = valid_prefix(addition, available)

    %{
      state
      | text: state.text <> captured,
        bytes: state.bytes + byte_size(captured),
        truncated?: byte_size(captured) < byte_size(addition)
    }
  end

  defp valid_prefix(_value, 0), do: ""

  defp valid_prefix(value, maximum_bytes) when byte_size(value) <= maximum_bytes, do: value

  defp valid_prefix(value, maximum_bytes) do
    value
    |> binary_part(0, maximum_bytes)
    |> remove_invalid_suffix()
  end

  defp remove_invalid_suffix(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> remove_invalid_suffix()
    end
  end

  defp split_chunks("", _maximum_bytes, chunks), do: Enum.reverse(chunks)

  defp split_chunks(text, maximum_bytes, chunks) do
    chunk = valid_prefix(text, maximum_bytes)
    remaining_bytes = byte_size(text) - byte_size(chunk)
    remaining = binary_part(text, byte_size(chunk), remaining_bytes)
    split_chunks(remaining, maximum_bytes, [chunk | chunks])
  end
end
