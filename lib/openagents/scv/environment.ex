defmodule OpenAgents.SCV.Environment do
  @moduledoc """
  Describes the runtime capabilities available to an SCV driver.

  The environment ID selects an immutable image at deployment time. It does not
  identify the SCV or the driver that runs inside the image.
  """

  @enforce_keys [:id, :image_name, :capabilities, :runtimes]
  defstruct [:id, :image_name, :capabilities, :runtimes]

  @type t :: %__MODULE__{
          id: String.t(),
          image_name: String.t(),
          capabilities: [atom()],
          runtimes: [String.t()]
        }

  @spec fetch(atom() | String.t()) :: {:ok, t()} | {:error, :environment_not_admitted}
  def fetch(environment) when environment in [:opencode_core, "opencode-core"] do
    {:ok,
     %__MODULE__{
       id: "opencode-core",
       image_name: "scv-opencode-core",
       capabilities: [
         :model_inference,
         :network_egress,
         :process_execute,
         :workspace_read,
         :workspace_write
       ],
       runtimes: ["elixir", "git", "node", "bun", "python"]
     }}
  end

  def fetch(environment) when environment in [:codex_app_server, "codex-app-server"] do
    {:ok,
     %__MODULE__{
       id: "codex-app-server",
       image_name: "openagents",
       capabilities: [
         :model_inference,
         :network_egress,
         :process_execute,
         :workspace_read
       ],
       runtimes: ["codex", "git"]
     }}
  end

  def fetch(_environment), do: {:error, :environment_not_admitted}

  @spec supports?(t(), [atom()]) :: boolean()
  def supports?(%__MODULE__{capabilities: available}, required) do
    MapSet.subset?(MapSet.new(required), MapSet.new(available))
  end
end
