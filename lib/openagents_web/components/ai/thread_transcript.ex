defmodule OpenAgentsWeb.AI.ThreadTranscript do
  @moduledoc """
  One thread transcript event, rendered through the shared AI Elements
  components — the same vocabulary `/chat` renders with.

  This module is the mapping from the thread event vocabulary onto the chat
  components: `turn.user` becomes a user `OpenAgentsWeb.AI.Conversation`
  message, `turn.reasoning` becomes the `OpenAgentsWeb.AI.Reasoning`
  reasoning disclosure, `tool.ran` becomes the tool block `ChatLive` renders
  tool activity with, and `turn.assistant` becomes an assistant message with
  the app's Markdown rendering. It is a shared function component rather
  than a private helper of the gym page so `OpenAgentsWeb.ThreadShowLive`
  can adopt the same rendering later instead of keeping a second vocabulary.

  Every payload field is client-written, so every read is defensive, exactly
  as `OpenAgentsWeb.ThreadShowLive` reads the same payloads: a missing or
  oddly typed field degrades the event to the neutral bounded raw row, an
  unknown event type takes the raw row too, and nothing here can crash the
  transcript around a malformed payload.
  """

  use OpenAgentsWeb, :html

  import OpenAgentsWeb.AI.Conversation, only: [message: 1, message_content: 1]

  import OpenAgentsWeb.AI.Reasoning,
    only: [
      reasoning: 1,
      reasoning_trigger: 1,
      reasoning_content: 1,
      tool: 1,
      tool_header: 1,
      tool_content: 1,
      tool_input: 1,
      tool_output: 1
    ]

  @bounded_json_characters 2_000

  @doc """
  One transcript entry, dispatched on its event type.

  `event` is an `OpenAgents.Threads.Event`. `id`, when given, prefixes the
  DOM ids of the inner components.
  """
  attr :id, :string, default: nil
  attr :event, :any, required: true

  def transcript_event(%{event: %{event_type: "turn.user"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns = assign(assigns, text: text, steered: steered?(event.payload))

        ~H"""
        <.message from="user" class="items-end">
          <.badge :if={@steered} variant={:warning} class="message-provenance">steered</.badge>
          <.message_content>
            <div class="whitespace-pre-wrap">{@text}</div>
          </.message_content>
        </.message>
        """
    end
  end

  def transcript_event(%{event: %{event_type: "turn.reasoning"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns = assign(assigns, :text, text)

        ~H"""
        <.reasoning id={@id && "#{@id}-reasoning"}>
          <.reasoning_trigger />
          <.reasoning_content text={@text} />
        </.reasoning>
        """
    end
  end

  def transcript_event(%{event: %{event_type: "tool.ran"} = event} = assigns) do
    case string(event.payload, ["tool", "name"]) do
      nil ->
        raw_row(assigns)

      tool_name ->
        assigns =
          assign(assigns,
            tool_name: tool_name,
            state: tool_state(string(event.payload, ["status"])),
            arguments: bounded_json(Map.get(event.payload, "arguments")),
            result: bounded_json(Map.get(event.payload, "result")),
            error: bounded_json(Map.get(event.payload, "error"))
          )

        ~H"""
        <.tool id={@id && "#{@id}-tool"} class="mb-0">
          <.tool_header type="dynamic-tool" tool_name={@tool_name} state={@state} />
          <.tool_content>
            <.tool_input :if={@arguments} input={@arguments} />
            <.tool_output :if={@result || @error} output={@result} error_text={@error} />
            <p :if={!@arguments && !@result && !@error} class="text-muted-foreground text-xs">
              The report carried no arguments and no result.
            </p>
          </.tool_content>
        </.tool>
        """
    end
  end

  def transcript_event(%{event: %{event_type: "turn.assistant"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns = assign(assigns, :text, text)

        ~H"""
        <.message from="assistant">
          <.message_content text={@text} />
        </.message>
        """
    end
  end

  def transcript_event(assigns), do: raw_row(assigns)

  # The neutral row: whatever the type, whatever the payload, it renders as
  # the recorded fact rather than crashing the transcript around it.
  defp raw_row(assigns) do
    assigns = assign(assigns, :json, bounded_json(assigns.event.payload))

    ~H"""
    <details class="rounded-md border border-border" data-transcript-raw="true">
      <summary class="flex cursor-pointer select-none items-center gap-2 px-3 py-2 text-xs">
        <code class="font-mono">{@event.event_type}</code>
        <span class="text-muted-foreground"><.time_ago at={@event.emitted_at} /></span>
      </summary>
      <pre
        :if={@json}
        class="overflow-x-auto border-t border-border px-3 py-2 font-mono text-xs"
      ><code phx-no-format>{@json}</code></pre>
    </details>
    """
  end

  # ── payload readers ──────────────────────────────────────────────────────

  defp text(payload), do: string(payload, ["text"])

  defp string(payload, keys) when is_map(payload) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp string(_payload, _keys), do: nil

  defp steered?(payload) when is_map(payload), do: Map.get(payload, "steered") == true
  defp steered?(_payload), do: false

  defp bounded_json(nil), do: nil

  defp bounded_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} when byte_size(json) > @bounded_json_characters ->
        String.slice(json, 0, @bounded_json_characters) <> "\n…"

      {:ok, json} ->
        json

      {:error, _unencodable} ->
        inspect(value, limit: 50, printable_limit: @bounded_json_characters)
    end
  end

  # The client-written status words mapped onto the AI SDK tool-part states
  # `tool_header/1` reads, the same narrowing `ChatLive` applies to durable
  # step statuses. `tool.ran` is past tense, so an absent or unrecognized
  # status reads as completed rather than inventing an error.
  defp tool_state("ok"), do: "output-available"
  defp tool_state("success"), do: "output-available"
  defp tool_state("succeeded"), do: "output-available"
  defp tool_state("error"), do: "output-error"
  defp tool_state("failed"), do: "output-error"
  defp tool_state("refused"), do: "output-denied"
  defp tool_state("denied"), do: "output-denied"
  defp tool_state("running"), do: "input-available"
  defp tool_state(_other), do: "output-available"
end
