defmodule OpenAgents.Forge.AnchorPublisher do
  @moduledoc """
  The scheduled job that publishes the WAL anchor (`EXIT-005`, ADR 0008).

  It sits beside `OpenAgents.Forge.MirrorWatch` and never on the push path.
  `OpenAgents.Forge.Pushes` acknowledges a push only after the WAL persists it,
  and everything after that barrier is derived and unable to fail the push;
  this job is not even on that side of the barrier, because a slow or failing
  anchor must not be able to refuse a push.

  It publishes every tick whether or not the log moved. An anchor whose
  repository section is unchanged still carries a fresh `published_at`, which
  is the only thing that tells a reader publication has not stopped — and #168
  is explicit that a stopped publication is indistinguishable from an outage
  until somebody notices.

  Failure is logged and retried next tick. There is nothing to escalate: an
  unpublished anchor is the condition `OpenAgents.Forge.Independence` already
  reports on `/status`.
  """

  use GenServer

  require Logger

  alias OpenAgents.Forge.Anchor

  @default_interval_ms 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    publish()
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "One publication pass. Public so a test can drive it without the timer."
  def publish do
    case Anchor.publish() do
      {:ok, anchor} ->
        {:ok, anchor}

      # The code is the atom itself, never an inspected payload:
      # `OpenAgents.LogSafety` keeps failure bodies out of operational lines.
      {:error, reason} ->
        Logger.warning("forge_wal_anchor_publish_failed code=#{reason}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning(
        "forge_wal_anchor_publish_failed code=#{OpenAgents.OperationalLog.code(error)}"
      )

      {:error, :publish_failed}
  end

  @doc "The publication interval, which is also the anchor's exposure window."
  def interval_ms do
    Application.get_env(:openagents, :forge_wal_anchor_interval_ms, @default_interval_ms)
  end

  defp schedule, do: Process.send_after(self(), :tick, interval_ms())
end
