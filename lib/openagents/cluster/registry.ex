defmodule OpenAgents.Cluster.Registry do
  @moduledoc """
  Cluster-aware wrapper around `Horde.Registry`.

  Used by the work and computer subsystems to locate and register singleton
  processes across the fleet. With no peers this is a one-member cluster that
  behaves like a local `Registry`.
  """

  @name OpenAgents.HordeRegistry

  def start_link(opts), do: Horde.Registry.start_link(opts)

  @spec lookup(atom() | pid(), term()) :: [{pid(), term()}]
  def lookup(name \\ @name, key), do: Horde.Registry.lookup(name, key)

  @spec register(atom() | pid(), term(), term()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(name \\ @name, key, value \\ []) do
    case Horde.Registry.lookup(name, key) do
      [{pid, _}] when pid != self() ->
        {:error, {:already_registered, pid}}

      _ ->
        Horde.Registry.register(name, key, value)
    end
  end

  @spec unregister(atom() | pid(), term()) :: :ok
  def unregister(name \\ @name, key) do
    Horde.Registry.unregister(name, key)
    :ok
  end
end
