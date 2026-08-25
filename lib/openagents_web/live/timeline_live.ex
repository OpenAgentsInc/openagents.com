defmodule OpenAgentsWeb.TimelineLive do
  @moduledoc """
  The account's unified timeline as a page.

  Every entry is rooted in the account's visitor. Only the current account's
  own coder, voice, and chat activity is shown, newest first.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Timeline

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    entries =
      Timeline.for_user(current_user)
      |> Enum.reverse()

    {:ok,
     socket
     |> assign(:page_title, "Timeline")
     |> assign(:entries, entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="timeline" class="mx-auto w-full max-w-5xl space-y-6 px-4 py-10">
        <.header>
          Timeline
          <:subtitle>Your account's activity, newest first.</:subtitle>
        </.header>

        <.empty :if={@entries == []} id="timeline-empty" title="No activity yet">
          Your chat, voice, and coder sessions appear here when they start.
        </.empty>

        <.table
          :if={@entries != []}
          id="timeline-table"
          rows={@entries}
          row_id={&"timeline-entry-#{&1.record_id}"}
        >
          <:col :let={entry} label="When">
            <span :if={is_nil(entry.timestamp)} class="text-muted-foreground">—</span>
            <.time_ago :if={entry.timestamp} at={entry.timestamp} />
          </:col>
          <:col :let={entry} label="Modality">
            {modality_label(entry.modality)}
          </:col>
          <:col :let={entry} label="Kind">
            <.badge variant={kind_variant(entry.kind)}>{kind_label(entry.kind)}</.badge>
          </:col>
          <:col :let={entry} label="Summary">
            {entry.summary}
          </:col>
        </.table>
      </main>
    </Layouts.app>
    """
  end

  defp modality_label(modality) do
    modality
    |> to_string()
    |> String.capitalize()
  end

  defp kind_label(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp kind_variant(:turn), do: :info
  defp kind_variant(:tool_step), do: :warning
  defp kind_variant(:decision), do: :success
  defp kind_variant(:system), do: :default
  defp kind_variant(_kind), do: :default
end
