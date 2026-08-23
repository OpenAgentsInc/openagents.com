defmodule OpenAgents.Capacity.Requirement do
  @moduledoc false

  @isolations ["managed_standard", "managed_strong", "customer_controlled"]
  @egresses ["policy_broker", "customer_network"]
  @locations ["openagents_managed", "customer_premises"]
  @targets ["openagents_managed", "customer_computer"]

  def normalize(%{"requirement" => requirement}) when is_map(requirement),
    do: normalize(requirement)

  def normalize(requirement) when is_map(requirement) do
    quantity = Map.get(requirement, "quantity", 1)
    target = Map.get(requirement, "target", "openagents_managed")
    tools = Map.get(requirement, "tools", [])
    duration = Map.get(requirement, "duration_seconds", 900)
    isolation = Map.get(requirement, "isolation")
    egress = Map.get(requirement, "egress")
    location = Map.get(requirement, "data_location")
    computer_id = Map.get(requirement, "computer_id")
    budget = Map.get(requirement, "budget")

    cond do
      not positive_integer?(quantity) or quantity > 1_000 or
        not positive_integer?(duration) or duration > 86_400 ->
        {:error, :invalid_requirement, "Quantity and duration are out of bounds."}

      not is_binary(isolation) ->
        {:error, :invalid_requirement, "Isolation is required."}

      isolation not in @isolations ->
        {:error, :unsupported_isolation, "No admitted class provides #{isolation}."}

      not is_binary(egress) ->
        {:error, :invalid_requirement, "Egress is required."}

      egress not in @egresses ->
        {:error, :unsupported_egress, "No admitted class provides #{egress}."}

      not is_binary(location) ->
        {:error, :invalid_requirement, "Data location is required."}

      location not in @locations ->
        {:error, :unsupported_data_location, "No class runs in #{location}."}

      target not in @targets ->
        {:error, :invalid_requirement, "Target is invalid."}

      target == "customer_computer" and not is_binary(computer_id) ->
        {:error, :explicit_target_required, "A customer computer target requires computer_id."}

      not is_list(tools) or Enum.any?(tools, &(not is_binary(&1))) ->
        {:error, :invalid_requirement, "Tools must be a list of strings."}

      not valid_budget?(budget) ->
        {:error, :invalid_requirement, "Budget must use usd_cents."}

      true ->
        {:ok,
         %{
           "quantity" => quantity,
           "isolation" => isolation,
           "egress" => egress,
           "data_location" => location,
           "target" => target,
           "tools" => Enum.uniq(tools),
           "duration_seconds" => duration,
           "budget" => normalize_budget(budget)
         }
         |> maybe_put_computer(computer_id)}
    end
  end

  def normalize(_invalid), do: {:error, :invalid_requirement, "Requirement must be an object."}

  defp maybe_put_computer(requirement, computer_id) when is_binary(computer_id),
    do: Map.put(requirement, "computer_id", computer_id)

  defp maybe_put_computer(requirement, _computer_id), do: requirement

  defp normalize_budget(nil), do: nil

  defp normalize_budget(%{"currency" => currency, "amount" => amount}),
    do: %{"currency" => currency, "amount" => amount}

  defp valid_budget?(nil), do: true

  defp valid_budget?(%{"currency" => "usd_cents", "amount" => amount})
       when is_integer(amount) and amount >= 0, do: true

  defp valid_budget?(_budget), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
