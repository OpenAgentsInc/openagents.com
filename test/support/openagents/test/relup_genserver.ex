defmodule OpenAgents.Test.RelupGenServer do
  @moduledoc """
  Versioned GenServer used to prove `code_change/3` state migrations.
  """

  use GenServer

  defstruct [:counter, :version]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    counter = Keyword.get(opts, :counter, 0)
    {:ok, %__MODULE__{counter: counter, version: 1}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def code_change(1, %__MODULE__{counter: counter}, _extra) do
    {:ok, %__MODULE__{counter: counter + 1, version: 2}}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end
end
