defmodule OpenAgents.BoxRunSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)
end
