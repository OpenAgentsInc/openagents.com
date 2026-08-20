defmodule OpenAgents.Forge.Janitor do
  @moduledoc """
  Retention for the forge's node-local caches (roadmap P6, issue #123):
  hourly, bounded, and quiet —

  - **Stale per-job clones**: a clone under the coding jobs dir whose job is
    terminal (its clone should already be gone — `Work.Coding.on_terminal`
    removes it) or unknown, and whose mtime is older than the retention
    window, is pruned. Covers workers that died between mutation and
    cleanup.
  - **Stale beam artifacts**: `beams/<sha>.tar` files older than the window
    that are NOT the current live target's artifact are pruned — the WAL and
    receipts remain the durable record; the tars are cache.

  Never touches bare repos or the WAL: those are re-materializable truth,
  not cache to expire.
  """

  use GenServer

  require Logger

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Tools.Repository

  @tick_ms 60 * 60 * 1000
  @retention_ms 24 * 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    _swept = sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "One sweep; returns {pruned_clones, pruned_artifacts}. Public for tests."
  def sweep(now_ms \\ System.system_time(:millisecond)) do
    # F1 (#124): the WAL→receipt replayer rides the same slow tick — any
    # push receipt lost to a crash or restore is re-derived, exactly once
    # by WAL index position.
    Enum.each(Repos.allowed_repos(), fn repo ->
      safely(fn -> OpenAgents.Forge.Pushes.reconcile_receipts(repo) end)
    end)

    {sweep_clones(now_ms), sweep_artifacts(now_ms)}
  rescue
    error ->
      Logger.warning("forge_janitor_sweep_failed code=#{OpenAgents.OperationalLog.code(error)}")
      {0, 0}
  end

  defp sweep_clones(now_ms) do
    jobs_dir = Repository.jobs_dir()

    case File.ls(jobs_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "job-"))
        |> Enum.count(fn entry ->
          path = Path.join(jobs_dir, entry)

          if stale?(path, now_ms) and not active_job?(entry) do
            File.rm_rf(path)
            Logger.info("forge janitor: pruned stale job clone #{entry}")
            true
          else
            false
          end
        end)

      {:error, _reason} ->
        0
    end
  end

  defp sweep_artifacts(now_ms) do
    beams_dir = Path.join(Repos.data_dir(), "beams")
    live_artifact = current_live_artifact()

    case File.ls(beams_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".tar"))
        |> Enum.count(fn entry ->
          path = Path.join(beams_dir, entry)

          if Path.join("beams", entry) != live_artifact and stale?(path, now_ms) do
            File.rm(path)
            true
          else
            false
          end
        end)

      {:error, _reason} ->
        0
    end
  end

  defp current_live_artifact do
    case Targets.current(Repository.repo()) do
      %{status: "live", details: %{"artifact" => relative}} -> relative
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp stale?(path, now_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now_ms - mtime * 1000 > @retention_ms
      {:error, _reason} -> false
    end
  end

  # A job whose row is still active keeps its clone regardless of age.
  defp active_job?("job-" <> job_id) do
    case Ecto.UUID.cast(job_id) do
      {:ok, _uuid} ->
        case OpenAgents.Repo.get(OpenAgents.Work.Job, job_id) do
          %{status: status} -> status in ~w(queued running)
          nil -> false
        end

      :error ->
        false
    end
  rescue
    _error -> true
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick_ms)

  defp safely(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
