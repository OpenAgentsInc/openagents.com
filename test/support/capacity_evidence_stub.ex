defmodule OpenAgents.CapacityEvidenceStub do
  @moduledoc false

  def fetch(_viewer),
    do: Application.get_env(:openagents, :capacity_test_evidence, {:error, :unset})
end
