defmodule OpenAgents.Cluster.DynamicSupervisor do
  @moduledoc """
  Local-only replacement for Horde.DynamicSupervisor.
  """

  @name OpenAgents.HordeSupervisor

  @spec start_child(atom() | pid(), {module(), term()} | map()) ::
          DynamicSupervisor.on_start_child()
  def start_child(name \\ @name, spec) do
    spec =
      case spec do
        {mod, arg} -> {mod, arg}
        %{} -> spec
        _ when is_tuple(spec) -> spec
      end

    DynamicSupervisor.start_child(name, spec)
  end
end
