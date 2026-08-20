defmodule OpenAgents.Cluster.DynamicSupervisor do
  @moduledoc """
  Cluster-aware wrapper around `Horde.DynamicSupervisor`.
  """

  @name OpenAgents.HordeSupervisor

  def start_link(opts), do: Horde.DynamicSupervisor.start_link(opts)

  @spec start_child(atom() | pid(), {module(), term()} | map()) ::
          DynamicSupervisor.on_start_child()
  def start_child(name \\ @name, spec) do
    spec =
      case spec do
        {mod, arg} -> {mod, arg}
        %{} -> spec
        _ when is_tuple(spec) -> spec
      end

    Horde.DynamicSupervisor.start_child(name, spec)
  end
end
