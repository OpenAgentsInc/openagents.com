defmodule OpenAgents.Observability.ReleaseGate do
  @moduledoc "Zero-tolerance privacy/provenance gate plus explicit operational warnings."

  @blocking ~w(cross_scope_private_leakage missing_collective_consent missing_turn_provenance missing_executor_disclosure failed_attribution_reconciliation)
  @warnings ~w(stuck_turns stuck_tool_steps)

  def thresholds,
    do: %{blocking: Map.new(@blocking, &{&1, 0}), warning: Map.new(@warnings, &{&1, 0})}

  def evaluate(readback) when is_map(readback) do
    integrity = readback[:integrity] || readback["integrity"] || %{}
    blockers = exceeded(integrity, @blocking)
    warnings = exceeded(integrity, @warnings)

    %{
      schema: "openagents.observability.release_gate.v1",
      status: if(blockers == [], do: "passed", else: "blocked"),
      blockers: blockers,
      warnings: warnings,
      thresholds: thresholds()
    }
  end

  defp exceeded(integrity, keys) do
    Enum.flat_map(keys, fn key ->
      count = Map.get(integrity, key, Map.get(integrity, String.to_atom(key), 0))

      if is_integer(count) and count > 0,
        do: [%{check: key, count: count, threshold: 0}],
        else: []
    end)
  end
end
