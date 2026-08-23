defmodule OpenAgents.Test.RollingAuthority do
  @moduledoc false

  use Agent

  def start_link(initial \\ %{}) do
    Agent.start_link(
      fn ->
        %{
          authorized: nil,
          observed: %{},
          calls: [],
          fleet_events_at_authorization: nil,
          refuse: initial[:refuse]
        }
      end,
      name: __MODULE__
    )
  end

  def authorized, do: Agent.get(__MODULE__, & &1.authorized)
  def observed, do: Agent.get(__MODULE__, & &1.observed)
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @doc "Whatever the fleet provider had already done when authorization ran."
  def fleet_events_at_authorization,
    do: Agent.get(__MODULE__, & &1.fleet_events_at_authorization)

  def authorize_rolling_replacement(target_id, identity) do
    fleet_events = OpenAgents.Test.RollingProvider.events()

    Agent.get_and_update(__MODULE__, fn state ->
      state = %{
        state
        | authorized: {target_id, identity},
          fleet_events_at_authorization: fleet_events,
          calls: [{:authorize, target_id} | state.calls]
      }

      case state.refuse do
        nil -> {{:ok, %{id: target_id}}, state}
        reason -> {{:error, reason}, state}
      end
    end)
  end

  def record_rolling_node(target_id, node, observation) do
    Agent.get_and_update(__MODULE__, fn state ->
      {{:ok, %{id: target_id}},
       %{
         state
         | observed: Map.put(state.observed, to_string(node), observation),
           calls: [{:record, to_string(node)} | state.calls]
       }}
    end)
  end
end
