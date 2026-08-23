defmodule OpenAgentsWeb.LiveRefresh do
  @moduledoc """
  One re-armed timer per LiveView, so a burst of announcements costs one
  re-read.

  Every live surface here follows the same shape (#154). A context announces
  that something moved and carries an id, never a payload; the subscriber
  re-reads through the same authorized read that filled the assign at mount,
  so a viewer can never be handed a row -- or a row counted into a number --
  the database would have refused them.

  Without a timer that shape repaints once per event, and an import walking a
  board or a script closing a milestone's worth of issues costs one read per
  row. Each announcement instead marks the panel it moved stale and re-arms
  the same timer: only the last one fires, and only the panels that moved
  re-read.

  A quarter of a second is long enough to absorb a burst and short enough that
  a person who wrote in another tab sees the number move before they look
  back. Tests run the interval at zero and refresh inline, so an assertion
  never depends on wall time.

  Use it in three lines:

      def mount(_params, _session, socket) do
        if connected?(socket), do: Forum.subscribe_posts()
        {:ok, socket |> LiveRefresh.init() |> assign_posts()}
      end

      def handle_info({:forum_posts_changed, _id}, socket),
        do: {:noreply, LiveRefresh.mark_stale(socket, :posts, &refresh_panel/2)}

      def handle_info(:live_refresh, socket),
        do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  where `refresh_panel/2` takes the socket and one stale panel and returns the
  socket with that panel re-read.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]

  @message :live_refresh

  @interval_ms if Application.compile_env(:openagents, :runtime_environment) == :test,
                 do: 0,
                 else: 250

  @doc "The message the armed timer sends. Match it in `handle_info/2`."
  def message, do: @message

  @doc "How long announcements collect before the re-read, in milliseconds."
  def interval_ms, do: @interval_ms

  @doc "Prepares a socket to collect stale panels. Call once, at mount."
  def init(socket) do
    socket
    |> assign(:refresh_timer_ref, nil)
    |> assign(:stale_panels, MapSet.new())
  end

  @doc """
  Marks `panel` stale and re-arms the timer.

  Under the zero interval tests run at, `refresh_panel` is called inline
  instead, so an assertion reads the refreshed page rather than waiting for it.
  """
  def mark_stale(socket, panel, refresh_panel) when is_function(refresh_panel, 2) do
    socket = update(socket, :stale_panels, &MapSet.put(&1, panel))

    if @interval_ms == 0, do: run(socket, refresh_panel), else: rearm(socket)
  end

  @doc "Re-reads every panel marked stale since the last run."
  def run(socket, refresh_panel) when is_function(refresh_panel, 2) do
    socket.assigns.stale_panels
    |> Enum.reduce(socket, &refresh_panel.(&2, &1))
    |> assign(:stale_panels, MapSet.new())
    |> assign(:refresh_timer_ref, nil)
  end

  defp rearm(socket) do
    case socket.assigns.refresh_timer_ref do
      nil -> :ok
      ref when is_reference(ref) -> Process.cancel_timer(ref)
    end

    assign(socket, :refresh_timer_ref, Process.send_after(self(), @message, @interval_ms))
  end
end
