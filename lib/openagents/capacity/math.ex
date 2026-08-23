defmodule OpenAgents.Capacity.Math do
  @moduledoc false

  def quantities(class, evidence, config) do
    logical = integer_or_nil(evidence["logical"])
    active = integer_or_nil(evidence["active_reservations"])
    reported_free = integer_or_nil(evidence["reported_free"])
    observed = integer_or_nil(evidence["observed_limit"])
    budget_limit = integer_or_nil(evidence["budget_limit"])
    drain_limit = integer_or_nil(evidence["drain_limit"])
    ceiling = integer_or_nil(Keyword.get(config, :class_ceilings, %{})[class["id"]])
    fraction = Keyword.get(config, :reserved_headroom_fraction, 0.25)
    safety_headroom = if is_integer(observed), do: floor(observed * fraction), else: nil

    effective_limit =
      [ceiling, subtract(observed, safety_headroom), budget_limit, drain_limit]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> Enum.min(values)
      end

    limit_derived = subtract(effective_limit, active)

    allocatable =
      case {limit_derived, reported_free} do
        {nil, _} -> nil
        {derived, nil} -> max(derived, 0)
        {derived, free} -> max(min(derived, free), 0)
      end

    %{
      "logical" => logical,
      "active_reservations" => active,
      "allocatable" => allocatable,
      "queued" => integer_or_nil(evidence["queued"]),
      "safety_headroom" => safety_headroom,
      "configured_ceiling" => ceiling,
      "observed_limit" => observed
    }
  end

  defp subtract(nil, _value), do: nil
  defp subtract(value, nil), do: value
  defp subtract(value, other), do: value - other

  defp integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_nil(value) when is_float(value) and value >= 0, do: trunc(value)
  defp integer_or_nil(_value), do: nil
end
