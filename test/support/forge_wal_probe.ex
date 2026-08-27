defmodule OpenAgents.Forge.WAL.Probe do
  @moduledoc false

  @behaviour OpenAgents.Forge.WAL

  alias OpenAgents.Forge.WAL.Local

  @impl true
  def read_index(repo) do
    if pid = Application.get_env(:openagents, :forge_wal_probe_pid) do
      send(pid, {__MODULE__, :read_index, repo})
    end

    Local.read_index(repo)
  end

  @impl true
  defdelegate cas_index(repo, expected, index), to: Local

  @impl true
  defdelegate put_entry(repo, seq, payload), to: Local

  @impl true
  defdelegate put_entry_file(repo, seq, path), to: Local

  @impl true
  defdelegate get_entry(repo, object_key), to: Local

  @impl true
  defdelegate get_entry_file(repo, object_key, path), to: Local

  @impl true
  defdelegate put_object(repo, object_key, payload), to: Local

  @impl true
  defdelegate delete_repo(repo), to: Local
end
