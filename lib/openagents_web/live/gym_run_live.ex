defmodule OpenAgentsWeb.GymRunLive do
  @moduledoc """
  One Gym run, live: the run header, its trials as they report, and the
  selected trial's transcript streaming through the same conversation
  components `/chat` renders with.

  Operator-only the way `/gym` is: the route sits in the `:operator_chat`
  live session, the mount re-checks `OpenAgents.Accounts.admin?/1`, and
  every event re-checks it. An unknown run id redirects to `/gym` rather
  than confirming anything, matching how the operator surfaces route a
  reader back to the main flow.

  The transcript read path is `OpenAgents.Gym.fetch_trial_thread/1`: the
  viewer is any operator, not the thread's owner, so the read resolves only
  through a stored trial linkage that was ownership-verified at ingest
  (INVARIANTS THREAD-001, ADMIN-001). The snapshot-to-live order follows
  the projection protocol `OpenAgentsWeb.ThreadShowLive` documents:
  subscribe to the thread's topic first, then read the snapshot, then let
  buffered broadcasts drain with a monotonic `last_event_id` dedup, so an
  event is never dropped and never doubled. Trials on a lane that leaves no
  thread render a state-only placeholder instead.
  """

  use OpenAgentsWeb, :live_view

  import OpenAgentsWeb.AI.Conversation,
    only: [conversation: 1, conversation_content: 1, shimmer: 1]

  import OpenAgentsWeb.AI.ThreadTranscript, only: [transcript_event: 1]

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run
  alias OpenAgents.Threads

  # Transcript pages are capped at 50 by the context; forty pages bounds the
  # snapshot at 2,000 events, the same bound `ThreadShowLive` holds.
  @maximum_pages 40

  @impl true
  def mount(%{"id" => run_id}, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      # Subscribe before the snapshot read, so a trial report that lands
      # between the two arrives as a message rather than being missed.
      if connected?(socket), do: Gym.subscribe_run(run_id)

      case Gym.fetch_run(run_id) do
        {:ok, run} ->
          socket =
            socket
            |> assign(:page_title, "Gym run")
            |> assign(:run, run)
            |> assign(:trials, run.trials)
            |> assign(:selected_trial_id, nil)
            |> assign(:thread, nil)
            |> assign(:last_event_id, 0)
            |> assign(:transcript, :none)
            |> assign(:events_empty?, true)
            |> stream(:events, [])
            |> select_trial(default_trial(run.trials))
            |> restream_trials()

          {:ok, socket}

        :error ->
          {:ok, redirect(socket, to: ~p"/gym")}
      end
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("select_trial", %{"id" => trial_id}, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      socket =
        case Enum.find(socket.assigns.trials, &(&1.id == trial_id)) do
          nil -> socket
          trial -> socket |> select_trial(trial) |> restream_trials()
        end

      {:noreply, socket}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:gym_run, %Run{} = run}, socket) do
    cond do
      !Accounts.admin?(socket.assigns.current_user) ->
        {:noreply, redirect(socket, to: ~p"/")}

      run.id == socket.assigns.run.id ->
        # The broadcast carries the run as stored, trials not loaded; the
        # trial list lives in its own assign, so only the header moves.
        {:noreply, assign(socket, :run, run)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:gym_trial, trial}, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      trials = upsert_trial(socket.assigns.trials, trial)
      socket = socket |> assign(:trials, trials) |> restream_trials()

      socket =
        cond do
          # The first reported trial becomes the selection, so an operator
          # watching an empty run is attached the moment work starts.
          socket.assigns.selected_trial_id == nil ->
            select_trial(socket, default_trial(trials))

          # The selected trial gained its thread link after selection.
          trial.id == socket.assigns.selected_trial_id and
            socket.assigns.transcript != :live and is_binary(trial.thread_id) ->
            select_trial(socket, trial)

          true ->
            socket
        end

      {:noreply, socket}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  def handle_info({:thread_event, event}, socket) do
    cond do
      !Accounts.admin?(socket.assigns.current_user) ->
        {:noreply, redirect(socket, to: ~p"/")}

      socket.assigns.thread == nil or event.thread_id != socket.assigns.thread.id ->
        {:noreply, socket}

      event.id <= socket.assigns.last_event_id ->
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> assign(:last_event_id, event.id)
         |> assign(:events_empty?, false)
         |> stream_insert(:events, event)}
    end
  end

  # ── selection ────────────────────────────────────────────────────────────

  defp default_trial(trials),
    do: Enum.find(trials, &(&1.state == "running")) || List.first(trials)

  defp select_trial(socket, nil) do
    socket
    |> detach_thread()
    |> assign(selected_trial_id: nil, transcript: :none, events_empty?: true, last_event_id: 0)
    |> stream(:events, [], reset: true)
  end

  defp select_trial(socket, trial) do
    socket = socket |> detach_thread() |> assign(:selected_trial_id, trial.id)

    if trial.thread_id == nil do
      socket
      |> assign(transcript: :no_thread, events_empty?: true, last_event_id: 0)
      |> stream(:events, [], reset: true)
    else
      attach_thread(socket, trial)
    end
  end

  defp attach_thread(socket, trial) do
    case Gym.fetch_trial_thread(trial.id) do
      {:ok, thread} ->
        # Attach the live subscriber before reading the snapshot: an append
        # that lands between the two arrives as a buffered message and is
        # deduped by id, so the gap cannot lose an event.
        if connected?(socket), do: Threads.subscribe(thread)

        events = transcript_snapshot(thread)

        socket
        |> assign(:thread, thread)
        |> assign(:transcript, :live)
        |> assign(:last_event_id, last_id(events))
        |> assign(:events_empty?, events == [])
        |> stream(:events, events, reset: true)

      :error ->
        socket
        |> assign(transcript: :unavailable, events_empty?: true, last_event_id: 0)
        |> stream(:events, [], reset: true)
    end
  end

  defp detach_thread(socket) do
    case socket.assigns[:thread] do
      nil ->
        socket

      thread ->
        if connected?(socket), do: Threads.unsubscribe(thread)
        assign(socket, :thread, nil)
    end
  end

  # Whether the selected trial is still running, for the threadless
  # placeholder: a running trial's thread is expected momentarily (the
  # harness links it as soon as the coder announces), while a finished
  # threadless trial ran on a lane that leaves no transcript.
  defp selected_trial_running?(trials, selected_trial_id) do
    Enum.any?(trials, &(&1.id == selected_trial_id and &1.state == "running"))
  end

  defp upsert_trial(trials, trial) do
    trials
    |> Enum.reject(&(&1.id == trial.id or &1.task == trial.task))
    |> then(&[trial | &1])
    |> Enum.sort_by(& &1.task)
  end

  defp restream_trials(socket) do
    socket
    |> assign(:trials_empty?, socket.assigns.trials == [])
    |> stream(:trials, socket.assigns.trials, reset: true)
  end

  # ── snapshot ─────────────────────────────────────────────────────────────

  defp transcript_snapshot(thread), do: transcript_snapshot(thread, nil, @maximum_pages, [])

  defp transcript_snapshot(_thread, _after_id, 0, pages),
    do: pages |> Enum.reverse() |> List.flatten()

  defp transcript_snapshot(thread, after_id, remaining, pages) do
    page = Threads.list_events(thread, after: after_id)

    case last_id(page) do
      0 -> transcript_snapshot(thread, after_id, 0, pages)
      last -> transcript_snapshot(thread, last, remaining - 1, [page | pages])
    end
  end

  defp last_id([]), do: 0
  defp last_id(events), do: List.last(events).id

  # ── presentation ─────────────────────────────────────────────────────────

  defp percent(nil), do: "—"
  defp percent(score), do: "#{Float.round(score * 100, 1)}%"

  defp status_variant("running"), do: :info
  defp status_variant("graded"), do: :success
  defp status_variant("abandoned"), do: :dim
  defp status_variant(_status), do: :default

  defp trial_variant("passed"), do: :success
  defp trial_variant("failed"), do: :danger
  defp trial_variant(_running_or_ungraded), do: :dim

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="gym-run" class="mx-auto w-full max-w-6xl space-y-6 px-4 py-10">
        <header class="space-y-3">
          <div class="flex flex-wrap items-center gap-3">
            <.badge id="gym-run-status" variant={status_variant(@run.status)}>
              {@run.status}
            </.badge>
            <span class="font-mono text-xs text-muted-foreground">{@run.id}</span>
          </div>
          <h1 class="text-2xl font-semibold tracking-tight">
            {@run.suite}
            <span class="text-muted-foreground">·</span>
            {@run.agent}<span
              :if={@run.agent_version}
              class="text-muted-foreground"
            >@{@run.agent_version}</span>
          </h1>
          <dl
            id="gym-run-facts"
            class="flex flex-wrap gap-x-6 gap-y-1 text-sm text-muted-foreground"
          >
            <div class="flex gap-1.5">
              <dt>Model</dt>
              <dd class="font-mono text-xs leading-5">{@run.model}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Lane</dt>
              <dd>{@run.lane || "—"}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Score</dt>
              <dd id="gym-run-score" class="tabular-nums">{percent(Run.score(@run))}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Recipe</dt>
              <dd class="max-w-xs truncate font-mono text-xs leading-5" title={@run.recipe_digest}>
                {@run.recipe_digest}
              </dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Started</dt>
              <dd><.time_ago at={@run.inserted_at} /></dd>
            </div>
            <div :if={@run.completed_at} class="flex gap-1.5">
              <dt>Completed</dt>
              <dd><.time_ago at={@run.completed_at} /></dd>
            </div>
          </dl>
        </header>

        <div class="grid gap-6 lg:grid-cols-[minmax(16rem,1fr)_2fr]">
          <section aria-label="Trials" class="space-y-3">
            <h2 class="text-sm font-medium text-muted-foreground">Trials</h2>

            <.empty :if={@trials_empty?} id="gym-run-trials-empty" title="No trials reported yet">
              Trials appear here as the harness launches them.
            </.empty>

            <div id="gym-run-trials" phx-update="stream" class="space-y-2">
              <button
                :for={{dom_id, trial} <- @streams.trials}
                id={dom_id}
                type="button"
                phx-click="select_trial"
                phx-value-id={trial.id}
                data-state={trial.state}
                data-selected={to_string(@selected_trial_id == trial.id)}
                class={[
                  "flex w-full items-center justify-between gap-3 rounded-md border px-3 py-2 text-left text-sm transition-colors",
                  if(@selected_trial_id == trial.id,
                    do: "border-primary bg-secondary",
                    else: "border-border hover:bg-secondary"
                  )
                ]}
              >
                <span class="min-w-0 truncate font-mono text-xs">{trial.task}</span>
                <%= if trial.state == "running" do %>
                  <.shimmer text="running" tag="span" class="shrink-0 text-xs" />
                <% else %>
                  <.badge variant={trial_variant(trial.state)} class="shrink-0">
                    {trial.state}
                  </.badge>
                <% end %>
              </button>
            </div>
          </section>

          <section aria-label="Transcript" class="space-y-3">
            <h2 class="text-sm font-medium text-muted-foreground">Transcript</h2>

            <%= case @transcript do %>
              <% :none -> %>
                <.empty id="gym-transcript-none" title="No trial selected">
                  Select a trial to read its transcript.
                </.empty>
              <% :no_thread -> %>
                <%= if selected_trial_running?(@trials, @selected_trial_id) do %>
                  <.empty id="gym-transcript-no-thread" title="Waiting for the thread">
                    The trial is running and its coder has not announced a
                    thread yet. The transcript attaches the moment it does.
                  </.empty>
                <% else %>
                  <.empty id="gym-transcript-no-thread" title="No transcript">
                    This trial's lane left no transcript.
                  </.empty>
                <% end %>
              <% :unavailable -> %>
                <.empty id="gym-transcript-unavailable" title="Transcript unavailable">
                  The linked thread no longer exists.
                </.empty>
              <% :live -> %>
                <div class="flex h-[36rem] flex-col overflow-hidden rounded-md border border-border">
                  <.conversation id="gym-conversation" aria-label="Trial transcript">
                    <.conversation_content id="gym-conversation-content">
                      <.empty :if={@events_empty?} id="gym-transcript-empty" title="No events yet">
                        The transcript fills as the trial works.
                      </.empty>
                      <div id="gym-transcript-events" phx-update="stream" class="contents">
                        <div
                          :for={{dom_id, event} <- @streams.events}
                          id={dom_id}
                          data-kind={event.event_type}
                        >
                          <.transcript_event id={dom_id} event={event} />
                        </div>
                      </div>
                    </.conversation_content>
                  </.conversation>
                </div>
            <% end %>
          </section>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
