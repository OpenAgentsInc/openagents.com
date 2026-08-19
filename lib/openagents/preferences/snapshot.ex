defmodule OpenAgents.Preferences.Snapshot do
  @moduledoc "Frozen account-owner preference generation for one turn."
  @enforce_keys [:owner_visitor_id, :generation, :captured_at, :ref]
  defstruct @enforce_keys
end
