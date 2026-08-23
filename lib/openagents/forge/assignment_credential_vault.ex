defmodule OpenAgents.Forge.AssignmentCredentialVault do
  @moduledoc """
  Holds newly minted assignment credentials in memory until their delegation
  worker consumes them.

  The vault is intentionally ephemeral. Assignment credentials remain digest-only
  in Postgres, and a process restart loses the plaintext rather than recovering it
  from durable state.
  """

  use GenServer

  @name __MODULE__

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @spec put(String.t(), String.t()) :: :ok
  def put(assignment_id, credential) when is_binary(assignment_id) and is_binary(credential) do
    GenServer.call(@name, {:put, assignment_id, credential})
  end

  @spec take(String.t()) :: String.t() | nil
  def take(assignment_id) when is_binary(assignment_id) do
    GenServer.call(@name, {:take, assignment_id})
  end

  @spec delete(String.t()) :: :ok
  def delete(assignment_id) when is_binary(assignment_id) do
    GenServer.cast(@name, {:delete, assignment_id})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, assignment_id, credential}, _from, state) do
    {:reply, :ok, Map.put(state, assignment_id, credential)}
  end

  def handle_call({:take, assignment_id}, _from, state) do
    {credential, next_state} = Map.pop(state, assignment_id)
    {:reply, credential, next_state}
  end

  @impl true
  def handle_cast({:delete, assignment_id}, state),
    do: {:noreply, Map.delete(state, assignment_id)}
end
