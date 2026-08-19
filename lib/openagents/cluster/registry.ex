defmodule OpenAgents.Cluster.Registry do
  @moduledoc """
  Local-only replacement for Horde.Registry.

  Used by the work and computer subsystems when fleet clustering is not
  available. Registers and looks up process-key pairs in a local `Registry`
  named `OpenAgents.HordeRegistry`.
  """

  @name OpenAgents.HordeRegistry

  @spec lookup(atom() | pid(), term()) :: [{pid(), term()}]
  def lookup(name \\ @name, key) do
    Registry.lookup(name, key)
  end

  @spec register(atom() | pid(), term(), term()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(name \\ @name, key, value \\ []) do
    case Registry.lookup(name, key) do
      [{pid, _}] when pid != self() ->
        {:error, {:already_registered, pid}}

      _ ->
        Registry.register(name, key, value)
        {:ok, self()}
    end
  end

  @spec unregister(atom() | pid(), term()) :: :ok
  def unregister(name \\ @name, key) do
    Registry.unregister(name, key)
    :ok
  end
end
