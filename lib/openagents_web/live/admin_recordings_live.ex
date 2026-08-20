defmodule OpenAgentsWeb.AdminRecordingsLive do
  @moduledoc """
  Lists bounded voice-call metadata and operator-only recording playback.

  The account panel remains the primary operator surface. This focused page
  restores recording qualification without exposing transcripts, prompts,
  provider identifiers, or recording bytes to ordinary accounts.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Admin
  alias OpenAgents.Admin.Call
  alias OpenAgents.Voice.Recordings

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      {:ok,
       socket
       |> assign(:page_title, "Voice recordings · OpenAgents")
       |> assign(:offset, 0)
       |> assign(:page_size, @page_size)
       |> assign(:recording_config, Recordings.config())
       |> stream_configure(:calls, dom_id: &"admin-call-#{&1.session_id}")
       |> load_page()}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event(event, _params, socket) when event in ["next_page", "previous_page"] do
    if Accounts.admin?(socket.assigns.current_user) do
      paginate(event, socket)
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  defp paginate("next_page", socket) do
    offset = socket.assigns.offset + @page_size

    if offset < socket.assigns.totals.calls do
      {:noreply, socket |> assign(:offset, offset) |> load_page()}
    else
      {:noreply, socket}
    end
  end

  defp paginate("previous_page", socket) do
    offset = max(socket.assigns.offset - @page_size, 0)
    {:noreply, socket |> assign(:offset, offset) |> load_page()}
  end

  defp load_page(socket) do
    calls = Admin.list_calls(limit: @page_size, offset: socket.assigns.offset)

    socket
    |> assign(:totals, Admin.recording_totals())
    |> assign(:calls_empty?, calls == [])
    |> assign(:page_count, length(calls))
    |> stream(:calls, calls, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Voice recordings"
      wide
    >
      <section id="admin-recordings-page" class="panel" aria-label="Voice call recordings">
        <header class="panel__header">
          <div>
            <h1 class="panel__title">Voice recordings</h1>
            <p class="text-muted-foreground">
              Audio is stored {sealed_label(@recording_config)} and deleted {@recording_config.retention_days} days after a call ends.
            </p>
          </div>
          <div class="admin-totals">
            <.badge variant={:dim}>{@totals.calls} calls</.badge>
            <.badge variant={:info}>{@totals.recorded} with audio</.badge>
            <.badge variant={:dim}>{format_bytes(@totals.byte_size)} stored</.badge>
          </div>
        </header>

        <div id="admin-recording-calls" phx-update="stream" class="admin-rows">
          <.empty
            :if={@calls_empty?}
            id="admin-recordings-empty"
            title="No voice calls yet"
          >
            Calls appear here after an account uses voice.
          </.empty>

          <.card :for={{dom_id, call} <- @streams.calls} id={dom_id}>
            <div class="admin-row">
              <div class="admin-identity">
                <.avatar
                  src={call.github_avatar_url}
                  alt=""
                  size={:sm}
                  fallback={String.first(call.github_login)}
                />
                <span>
                  <strong :if={Call.display_name(call)}>{Call.display_name(call)}</strong>
                  <span>@{call.github_login}</span>
                </span>
              </div>

              <div class="admin-state">
                <.badge variant={status_variant(call.status)}>{String.upcase(call.status)}</.badge>
                <.badge :if={call.termination_reason} variant={:dim}>
                  {call.termination_reason}
                </.badge>
                <.badge :if={call.failure_code} variant={:danger}>{call.failure_code}</.badge>
              </div>

              <dl class="admin-meta">
                <div>
                  <dt>Started</dt><dd>{format_timestamp(call.started_at)}</dd>
                </div>
                <div>
                  <dt>Call length</dt><dd>{format_call_length(call)}</dd>
                </div>
                <div>
                  <dt>Model</dt><dd>{call.model_id}</dd>
                </div>
                <div>
                  <dt>Tokens</dt><dd>{format_count(call.total_tokens)}</dd>
                </div>
                <div>
                  <dt>Transcript</dt><dd>{format_count(call.transcript_item_count)} items</dd>
                </div>
                <div :if={call.recording}>
                  <dt>Audio</dt>
                  <dd>{format_bytes(call.recording.byte_size)} · {Call.completeness(call)}</dd>
                </div>
              </dl>

              <.audio_player
                :if={Call.playable?(call)}
                id={"admin-audio-#{call.session_id}"}
                src={~p"/admin/recordings/#{call.recording.id}/audio"}
                label={"Call with @#{call.github_login} on #{format_timestamp(call.started_at)}"}
              />

              <p :if={!Call.playable?(call)} class="admin-absence">{Call.absence_reason(call)}</p>
            </div>
          </.card>
        </div>

        <nav :if={@totals.calls > @page_size} class="admin-pager" aria-label="Call pages">
          <.button
            id="admin-recordings-previous"
            variant={:secondary}
            size={:sm}
            disabled={@offset == 0}
            phx-click="previous_page"
          >
            Previous
          </.button>
          <span>{@offset + 1}–{@offset + @page_count} of {@totals.calls}</span>
          <.button
            id="admin-recordings-next"
            variant={:secondary}
            size={:sm}
            disabled={@offset + @page_size >= @totals.calls}
            phx-click="next_page"
          >
            Next
          </.button>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  defp sealed_label(%{sealed?: true}), do: "encrypted"
  defp sealed_label(%{sealed?: false}), do: "unencrypted"

  defp status_variant("ended"), do: :dim
  defp status_variant("failed"), do: :danger
  defp status_variant(_active), do: :success

  defp format_call_length(%Call{recording: %{client_duration_ms: ms}}) when is_integer(ms),
    do: format_duration_ms(ms)

  defp format_call_length(%Call{started_at: started, ended_at: ended})
       when not is_nil(started) and not is_nil(ended),
       do: started |> DateTime.diff(ended, :millisecond) |> abs() |> format_duration_ms()

  defp format_call_length(%Call{}), do: "—"

  defp format_duration_ms(ms) do
    total_seconds = div(ms, 1_000)

    "#{div(total_seconds, 60)}:#{total_seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_024, do: "#{bytes} B"

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp format_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(_bytes), do: "0 B"

  defp format_count(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
