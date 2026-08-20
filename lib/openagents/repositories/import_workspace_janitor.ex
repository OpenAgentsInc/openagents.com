defmodule OpenAgents.Repositories.ImportWorkspaceJanitor do
  @moduledoc "Removes a bounded set of stale, crash-left GitHub import workspaces."

  use GenServer

  require Logger

  @default_interval_ms 15 * 60 * 1_000
  @default_retention_ms 2 * 60 * 60 * 1_000
  @maximum_entries 100
  @workspace_pattern ~r/\Aopenagents-import-[0-9a-f-]{36}-[0-9]+\z/

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc "Removes up to 100 stale import workspaces and returns the removal count."
  def sweep(now_ms \\ System.system_time(:millisecond)) do
    root = Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!())

    retention_ms =
      Application.get_env(
        :openagents,
        :repository_import_workspace_retention_ms,
        @default_retention_ms
      )

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@workspace_pattern, &1))
        |> Enum.sort()
        |> Enum.take(@maximum_entries)
        |> Enum.count(fn entry ->
          remove_if_stale(Path.join(root, entry), now_ms, retention_ms)
        end)

      {:error, _reason} ->
        0
    end
  end

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, @default_interval_ms)
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:sweep, state) do
    _count = sweep()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remove_if_stale(path, now_ms, retention_ms)
       when is_integer(retention_ms) and retention_ms >= 0 do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} when now_ms - mtime * 1_000 > retention_ms ->
        case File.rm_rf(path) do
          {:ok, _paths} ->
            Logger.info("repository import janitor removed a stale workspace")
            true

          {:error, _reason, _path} ->
            false
        end

      _other ->
        false
    end
  end

  defp remove_if_stale(_path, _now_ms, _retention_ms), do: false

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)
end
