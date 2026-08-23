defmodule OpenAgents.Forge.CacheReadiness do
  @moduledoc """
  Tracks repository caches that this node cannot materialize from the WAL.

  A successful synchronization clears the repository's failure. Readiness
  returns only when no observed cache failure remains.
  """

  use GenServer

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(options, :name, __MODULE__))
  end

  def mark_unavailable(repo, code) do
    GenServer.call(__MODULE__, {:mark_unavailable, repo, code})
  end

  def mark_available(repo) do
    GenServer.call(__MODULE__, {:mark_available, repo})
  end

  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  def report do
    GenServer.call(__MODULE__, :report)
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(failures), do: {:ok, failures}

  @impl true
  def handle_call({:mark_unavailable, repo, code}, _from, failures) do
    {:reply, :ok, Map.put(failures, repo, code)}
  end

  def handle_call({:mark_available, repo}, _from, failures),
    do: {:reply, :ok, Map.delete(failures, repo)}

  def handle_call(:ready?, _from, failures),
    do: {:reply, map_size(failures) == 0, failures}

  def handle_call(:report, _from, failures),
    do: {:reply, %{"ready" => map_size(failures) == 0, "failures" => failures}, failures}

  def handle_call(:reset, _from, _failures), do: {:reply, :ok, %{}}
end
