defmodule OpenAgents.Turns do
  @moduledoc """
  Supervises one temporary process per active response turn.
  """

  alias OpenAgents.Conversations
  alias OpenAgents.Turns.TurnServer

  def start(turn_id) do
    DynamicSupervisor.start_child(OpenAgents.TurnSupervisor, {TurnServer, turn_id})
  end

  def cancel(turn_id) do
    case Registry.lookup(OpenAgents.TurnRegistry, turn_id) do
      [{pid, _value}] -> GenServer.call(pid, :cancel)
      [] -> cancel_persisted(turn_id)
    end
  end

  defp cancel_persisted(turn_id) do
    turn = Conversations.get_turn!(turn_id)

    if turn.status in ["queued", "streaming"],
      do: Conversations.cancel_turn(turn),
      else: {:ok, turn}
  end
end
