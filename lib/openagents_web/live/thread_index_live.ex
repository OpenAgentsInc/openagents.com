defmodule OpenAgentsWeb.ThreadIndexLive do
  @moduledoc """
  The account's threads as a shell projection.

  Each row reads only the denormalized thread record — status, objective,
  counts, timestamps, terminal usage — never the transcript (issue #201's
  shell/detail split). The row title is the thread's objective: it is what the
  reader asked for, it lives on the shell row, and deriving the first
  `turn.user` event would mean reading transcripts for a listing. The list is a
  snapshot taken at mount; live updates belong to the detail page, which
  subscribes to its one thread's topic.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Threads

  @title_characters 100

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    _reaped = Threads.reap_expired(user)

    threads = Threads.list_for_user(user)

    {:ok,
     socket
     |> assign(:page_title, "Threads · OpenAgents")
     |> assign(:threads_empty?, threads == [])
     |> stream(:threads, threads)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="thread-index" class="mx-auto w-full max-w-5xl space-y-6 px-4 py-10">
        <.header>
          Threads
          <:subtitle>Every thread this account has opened, newest first.</:subtitle>
        </.header>

        <.empty :if={@threads_empty?} id="threads-empty" title="No threads yet">
          Open one with
          <.kbd>openagents coder</.kbd>
          or <.kbd>POST /api/v3/threads</.kbd>.
        </.empty>

        <.table :if={!@threads_empty?} id="threads-table" rows={@streams.threads}>
          <:col :let={{_id, thread}} label="Objective">
            <.link
              navigate={~p"/threads/#{thread.id}"}
              id={"thread-link-#{thread.id}"}
              class="font-medium hover:underline"
            >
              {title(thread.objective)}
            </.link>
          </:col>
          <:col :let={{_id, thread}} label="Status">
            <.badge variant={status_variant(thread.status)}>{thread.status}</.badge>
          </:col>
          <:col :let={{_id, thread}} label="Events">
            <span class="tabular-nums">{thread.event_count}</span>
          </:col>
          <:col :let={{_id, thread}} label="Model">
            <span class="font-mono text-xs text-muted-foreground">{thread.model}</span>
          </:col>
          <:col :let={{_id, thread}} label="Opened">
            <.time_ago at={thread.started_at} class="text-muted-foreground" />
          </:col>
          <:col :let={{_id, thread}} label="Last event">
            <.time_ago at={thread.updated_at} class="text-muted-foreground" />
          </:col>
          <:col :let={{_id, thread}} label="Spent">
            <span class="tabular-nums text-muted-foreground">{spent(thread.usage)}</span>
          </:col>
        </.table>
      </main>
    </Layouts.app>
    """
  end

  defp title(objective) do
    if String.length(objective) > @title_characters do
      String.slice(objective, 0, @title_characters) <> "…"
    else
      objective
    end
  end

  defp status_variant("open"), do: :info
  defp status_variant("succeeded"), do: :success
  defp status_variant("failed"), do: :danger
  defp status_variant("cancelled"), do: :dim
  defp status_variant(_status), do: :default

  # The terminal usage map is client-reported and its shape is not pinned, so
  # this reads the keys the grant meter uses and shows nothing otherwise.
  defp spent(usage) when is_map(usage) do
    case integer(usage, "estimated_cost_microusd") do
      nil ->
        case integer(usage, "total_tokens") do
          nil -> "—"
          tokens -> "#{tokens} tok"
        end

      microusd ->
        "$#{:erlang.float_to_binary(microusd / 1_000_000, decimals: 2)}"
    end
  end

  defp spent(_usage), do: "—"

  defp integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _absent -> nil
    end
  end
end
