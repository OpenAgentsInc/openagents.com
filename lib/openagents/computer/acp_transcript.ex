defmodule OpenAgents.Computer.AcpTranscript do
  @moduledoc """
  Decodes the controller's framed ACP progress stream into a human transcript.

  The live rail (`.DelegationLog` in `chat_live.ex`) already splits this wire
  format — record separator `0x1E` starts a frame, fields split on unit
  separator `0x1F`. Durable job reports used to post the raw bytes. This
  module is the server-side decoder so a timeout or completion never writes
  `Ttoolu_…0executeVGVybWluYWw=` into the conversation.

  `decode/1` renders the whole stream, prose and tool lines alike. A chat
  message wants less than that, so `summarize/1` splits the two: the agent's
  own words stay, and the tool-by-tool log becomes a count.
  """

  @record_separator <<30>>
  @unit_separator <<31>>

  @kind_labels %{
    "execute" => "Terminal",
    "read" => "Read",
    "edit" => "Edit",
    "search" => "Search",
    "fetch" => "Fetch",
    "think" => "Think",
    "move" => "Move",
    "delete" => "Delete"
  }

  @doc """
  Turns a collected ACP stream into readable prose + tool lines.

  Plain text with no record separators is returned unchanged. Incomplete
  trailing frames (no newline yet) are still parsed. Started tools that never
  received a done/failed phase are listed as in progress.
  """
  @spec decode(term()) :: String.t()
  def decode(binary) when is_binary(binary) do
    binary
    |> entries()
    |> render()
  end

  def decode(_other), do: ""

  @doc """
  Splits the stream into what a conversation can carry and what it cannot.

  Returns the agent's own prose, its notes, and the tool calls that failed —
  the parts that explain an outcome — plus the total number of tool calls.
  The tool-by-tool log belongs to the live delegation rail: pasted into a
  message it buries the report under hundreds of `Terminal: …` lines, so the
  caller names the count instead.
  """
  @spec summarize(term()) :: {String.t(), non_neg_integer()}
  def summarize(binary) when is_binary(binary) do
    entries = entries(binary)

    text =
      entries
      |> Enum.reject(&(&1.kind == :tool and &1.status != :failed))
      |> render()

    {text, Enum.count(entries, &(&1.kind == :tool))}
  end

  def summarize(_other), do: {"", 0}

  defp walk(<<@record_separator, rest::binary>>, acc, tools) do
    case take_line(rest) do
      {line, remaining} ->
        {acc, tools} = render_frame(line, acc, tools)
        walk(remaining, acc, tools)

      :done ->
        {acc, tools}
    end
  end

  defp walk(binary, acc, tools) when is_binary(binary) do
    case :binary.split(binary, @record_separator) do
      [prose] ->
        {append_prose(acc, prose), tools}

      [prose, rest] ->
        walk(<<@record_separator, rest::binary>>, append_prose(acc, prose), tools)
    end
  end

  defp take_line(""), do: :done

  defp take_line(binary) do
    case :binary.split(binary, "\n") do
      [line] -> {line, ""}
      [line, rest] -> {line, rest}
    end
  end

  # T | id | phase(0 start, 1 done, 2 failed) | kind | b64 title | b64 detail
  # N | b64 text | tone(info|warn|error)
  defp render_frame(line, acc, tools) do
    case String.split(line, @unit_separator) do
      ["T", id, phase, kind | rest] when is_binary(id) and id != "" ->
        {title, detail} = tool_payloads(rest)
        tools = put_tool(tools, id, phase, kind, title, detail)
        maybe_emit_tool(acc, id, phase, tools)

      ["N", encoded | rest] ->
        tone = Enum.at(rest, 0) || "info"
        {append_block(:note, acc, note_line(decode64(encoded), tone), nil), tools}

      _other ->
        {acc, tools}
    end
  end

  defp tool_payloads([title]), do: {decode64(title), ""}
  defp tool_payloads([title, detail | _rest]), do: {decode64(title), decode64(detail)}
  defp tool_payloads(_rest), do: {"", ""}

  defp put_tool(tools, id, phase, kind, title, detail) do
    previous =
      Map.get(tools, id, %{kind: kind, title: "", detail: "", phase: phase, emitted?: false})

    Map.put(tools, id, %{
      previous
      | kind: if(kind != "", do: kind, else: previous.kind),
        title: if(title != "", do: title, else: previous.title),
        detail: if(detail != "", do: detail, else: previous.detail),
        phase: phase
    })
  end

  defp maybe_emit_tool(acc, id, phase, tools) when phase in ["1", "2"] do
    tool = Map.fetch!(tools, id)

    if tool.emitted? do
      {acc, tools}
    else
      status = if phase == "2", do: :failed, else: :done

      {append_block(:tool, acc, tool_line(tool, status), status),
       Map.update!(tools, id, &Map.put(&1, :emitted?, true))}
    end
  end

  defp maybe_emit_tool(acc, _id, _phase, tools), do: {acc, tools}

  # The stream in reading order, each block tagged with what it is, so a caller
  # can keep the prose without the tool log.
  defp entries(binary) do
    {acc, tools} = walk(binary, [], %{})

    unfinished =
      tools
      |> Enum.reject(fn {_id, tool} -> tool.emitted? or tool.phase in ["1", "2"] end)
      |> Enum.map(fn {_id, tool} -> entry(:tool, tool_line(tool, :running), :running) end)

    Enum.reverse(acc) ++ unfinished
  end

  defp render(entries) do
    entries
    |> Enum.map_join("\n\n", & &1.text)
    |> String.trim()
  end

  defp entry(kind, text, status), do: %{kind: kind, text: text, status: status}

  defp append_prose(acc, text) do
    trimmed = String.trim(text)
    if trimmed == "", do: acc, else: [entry(:prose, trimmed, nil) | acc]
  end

  defp append_block(_kind, acc, block, _status) when block in [nil, ""], do: acc
  defp append_block(kind, acc, block, status), do: [entry(kind, block, status) | acc]

  defp tool_line(tool, status) do
    label = Map.get(@kind_labels, tool.kind, "")
    head = tool_head(label, tool.title)
    suffix = tool_suffix(status)
    body = if tool.detail != "", do: "\n#{String.trim(tool.detail)}", else: ""
    "#{head}#{suffix}#{body}"
  end

  defp tool_head(label, title) do
    cond do
      title != "" and label != "" and title != label -> "#{label}: #{title}"
      title != "" -> title
      label != "" -> label
      true -> "tool"
    end
  end

  defp tool_suffix(:failed), do: " (failed)"
  defp tool_suffix(:running), do: " (in progress)"
  defp tool_suffix(_done), do: ""

  defp note_line(text, tone) do
    prefix =
      case tone do
        "warn" -> "Warning: "
        "error" -> "Error: "
        _info -> "Note: "
      end

    prefix <> String.trim(text)
  end

  defp decode64(value) when is_binary(value) and value != "" do
    padded =
      case rem(byte_size(value), 4) do
        0 -> value
        n -> value <> String.duplicate("=", 4 - n)
      end

    case Base.decode64(padded, ignore: :whitespace) do
      {:ok, decoded} ->
        if String.valid?(decoded),
          do: decoded,
          else: decoded |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()

      :error ->
        ""
    end
  end

  defp decode64(_value), do: ""
end
