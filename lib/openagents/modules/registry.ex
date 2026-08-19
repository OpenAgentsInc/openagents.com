defmodule OpenAgents.Modules.Registry do
  @moduledoc "Provider-neutral access to the immutable module registry captured by a turn."

  alias OpenAgents.Modules.Artifact
  alias OpenAgents.Tools.{Registry, Snapshot}

  @spec fetch(Snapshot.t(), String.t(), pos_integer()) ::
          {:ok, Artifact.t()} | {:error, atom()}
  def fetch(%Snapshot{} = snapshot, module_id, version),
    do: Registry.fetch_module(snapshot, module_id, version)

  @spec discover(Snapshot.t()) :: [Artifact.t()]
  def discover(%Snapshot{} = snapshot) do
    snapshot.modules
    |> Map.values()
    |> Enum.filter(&Artifact.executable?/1)
    |> Enum.sort_by(&{&1.module_id, &1.version})
  end
end
