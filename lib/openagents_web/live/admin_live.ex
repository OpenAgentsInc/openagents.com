defmodule OpenAgentsWeb.AdminLive do
  @moduledoc """
  The operator surface: every voice call, newest first, with bounded recording
  metadata.

  Read-only by construction. `OpenAgents.Admin` exposes no write, so nothing here can
  ban an account, alter a conversation, or change configuration
  (`INVARIANTS.md` ADMIN-001). The only actions are paging and playback.

  Two presentation rules are deliberate:

    * Calls with no uploaded recording are listed with the reason. A panel that
      hid them would look like an empty history instead of an honest one.
    * Transcript *content* never appears, only whether a transcript exists. The
      operator has no recording-download route either; cross-account content
      access requires a separate decision and implementation.
  """

  use OpenAgentsWeb, :openagents_live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Admin
  alias OpenAgents.Admin.Call
  alias OpenAgents.Voice.Recordings

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      {:ok,
       socket
       |> assign(:page_title, "Operator · OpenAgents")
       |> assign(:offset, 0)
       |> assign(:recording_config, Recordings.config())
       |> load_page()}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event(event, _params, socket) when event in ["next_page", "previous_page"] do
    if Accounts.admin?(socket.assigns.current_user) do
      do_handle_event(event, socket)
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  def do_handle_event("next_page", socket) do
    offset = socket.assigns.offset + page_size()

    if offset < socket.assigns.totals.calls,
      do: {:noreply, socket |> assign(:offset, offset) |> load_page()},
      else: {:noreply, socket}
  end

  def do_handle_event("previous_page", socket) do
    offset = max(socket.assigns.offset - page_size(), 0)
    {:noreply, socket |> assign(:offset, offset) |> load_page()}
  end

  defp load_page(socket) do
    socket
    |> assign(:totals, Admin.recording_totals())
    |> assign(:calls, Admin.list_calls(limit: page_size(), offset: socket.assigns.offset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="admin-page" class="app-shell admin-shell">
        <%!-- The same bar every other surface renders, so moving between them
              reads as one application. The lockup carries only the way back:
              nothing in the product links here, and this is not a place to
              navigate onward from. --%>
        <Layouts.command_bar aria_label="OpenAgents operator panel" current_user={@current_user}>
          <:lockup>
            <.button
              id="return-to-conversation"
              variant={:chip}
              size={:xs}
              phx-click={JS.navigate(~p"/chat")}
            >
              <.icon name="arrow-left" /> RETURN TO CONVERSATION
            </.button>
          </:lockup>
        </Layouts.command_bar>

        <section class="admin" aria-label="Voice call recordings">
          <header class="admin-heading">
            <h1>Voice calls</h1>
            <p>
              Every call across every account, newest first. Audio is captured by the
              caller's browser and stored {sealed_label(@recording_config)}; it is
              deleted {@recording_config.retention_days} days after a call ends.
            </p>
            <div class="admin-totals">
              <.badge variant={:dim}>{@totals.calls} calls</.badge>
              <.badge variant={:info}>{@totals.recorded} with audio</.badge>
              <.badge variant={:dim}>{format_bytes(@totals.byte_size)} stored</.badge>
              <.badge :if={!@recording_config.enabled?} variant={:warning}>
                RECORDING OFF
              </.badge>
            </div>
          </header>

          <.empty :if={@calls == []} id="admin-empty" title="No voice calls yet">
            Calls appear here as soon as anyone talks with OpenAgents.
          </.empty>

          <ol :if={@calls != []} id="admin-calls" class="admin-rows">
            <li :for={call <- @calls} id={"admin-call-#{call.session_id}"}>
              <.card>
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
                    <.badge variant={status_variant(call.status)}>
                      {String.upcase(call.status)}
                    </.badge>
                    <.badge :if={call.termination_reason} variant={:dim}>
                      {call.termination_reason}
                    </.badge>
                    <.badge :if={call.failure_code} variant={:danger}>{call.failure_code}</.badge>
                  </div>

                  <dl class="admin-meta">
                    <div>
                      <dt>Started</dt>
                      <dd>{format_timestamp(call.started_at)}</dd>
                    </div>
                    <div>
                      <dt>Call length</dt>
                      <dd>{format_call_length(call)}</dd>
                    </div>
                    <div>
                      <dt>Model</dt>
                      <dd>{call.model_id}</dd>
                    </div>
                    <div>
                      <dt>Tokens</dt>
                      <dd>{format_count(call.total_tokens)}</dd>
                    </div>
                    <div>
                      <dt>Transcript</dt>
                      <dd>{format_count(call.transcript_item_count)} items</dd>
                    </div>
                    <div :if={call.recording}>
                      <dt>Audio</dt>
                      <dd>
                        {format_bytes(call.recording.byte_size)} · {Call.completeness(call)}
                      </dd>
                    </div>
                  </dl>

                  <p :if={is_nil(call.recording)} class="admin-absence">
                    {Call.absence_reason(call)}
                  </p>
                </div>
              </.card>
            </li>
          </ol>

          <nav :if={@totals.calls > page_size()} class="admin-pager" aria-label="Call pages">
            <.button
              id="admin-previous"
              variant={:secondary}
              size={:sm}
              disabled={@offset == 0}
              phx-click="previous_page"
            >
              <.icon name="arrow-left" /> NEWER
            </.button>
            <span>{page_label(@offset, @calls, @totals.calls)}</span>
            <.button
              id="admin-next"
              variant={:secondary}
              size={:sm}
              disabled={@offset + page_size() >= @totals.calls}
              phx-click="next_page"
            >
              OLDER
            </.button>
          </nav>
        </section>
      </main>
    </Layouts.app>
    """
  end

  # The panel is paged rather than streamed: an operator scanning recent calls
  # wants a bounded page and the recording projection remains metadata-only.
  defp page_size, do: 25

  defp page_label(offset, calls, total) do
    "#{offset + 1}–#{offset + length(calls)} of #{total}"
  end

  defp sealed_label(%{sealed?: true}), do: "encrypted"
  defp sealed_label(%{sealed?: false}), do: "unencrypted"

  defp status_variant("ended"), do: :dim
  defp status_variant("failed"), do: :danger
  defp status_variant(_active), do: :success

  # The browser's own duration claim when it uploaded one, otherwise the durable
  # session clock. Labeled the same either way, because neither is a measurement
  # of the audio itself.
  defp format_call_length(%Call{recording: %{client_duration_ms: ms}}) when is_integer(ms),
    do: format_duration_ms(ms)

  defp format_call_length(%Call{started_at: started, ended_at: ended})
       when not is_nil(started) and not is_nil(ended),
       do: started |> DateTime.diff(ended, :millisecond) |> abs() |> format_duration_ms()

  defp format_call_length(%Call{}), do: "—"

  defp format_duration_ms(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
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
