defmodule OpenAgents.Capacity.Estimate do
  @moduledoc false

  def build(class, requirement, queued, age_seconds, config) do
    hourly = unit_cost(class["id"], config)
    base = ceil(hourly * requirement["quantity"] * requirement["duration_seconds"] / 3_600)
    wait_low = if is_integer(queued), do: queued * 30, else: 0
    wait_high = if is_integer(queued), do: queued * 180, else: 180
    buyer = Keyword.get(config, :buyer)
    {earnings_value, earnings_reason} = earnings(buyer, base, requirement)
    maximum_age = Keyword.get(config, :maximum_evidence_age_seconds, 120)

    %{
      "cost" => %{
        "currency" => "usd_cents",
        "low" => base,
        "high" => max(base, base * 4),
        "basis" => "requested_quantity"
      },
      "completion_seconds" => %{
        "low" => 120 + wait_low,
        "high" => 960 + wait_high
      },
      "confidence" => if(age_seconds && age_seconds <= maximum_age, do: "medium", else: "low"),
      "evidence_age_seconds" => age_seconds,
      "assumptions" => [
        "One unit of the class runs the whole job.",
        "Queue wait uses the current observed queue depth."
      ],
      "earnings" => earnings_value,
      "earnings_reason" => earnings_reason
    }
  end

  def unit_cost(class_id, config) do
    costs =
      Keyword.get(config, :unit_cost_usd_cents_per_hour, %{
        "standard" => 16,
        "strong" => 32,
        "batch" => 8,
        "connected" => 0
      })

    value = costs[class_id] || 0
    if is_number(value) and value >= 0, do: value, else: 0
  end

  defp earnings(buyer, base, _requirement) when is_map(buyer) do
    if is_binary(buyer["name"]) and buyer["name"] != "" and
         buyer["verified_payout_policy"] == true do
      {%{"currency" => "usd_cents", "low" => base, "high" => base * 2}, nil}
    else
      {nil,
       if(is_binary(buyer["name"]) and buyer["name"] != "",
         do: "no_verified_payout_policy",
         else: "no_named_buyer"
       )}
    end
  end

  defp earnings(_buyer, _base, _requirement), do: {nil, "no_named_buyer"}
end
