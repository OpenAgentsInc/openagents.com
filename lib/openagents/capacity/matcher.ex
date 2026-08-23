defmodule OpenAgents.Capacity.Matcher do
  @moduledoc false

  alias OpenAgents.Capacity.{Catalog, Estimate}

  def match(projection, requirement, config) do
    classes = projection["classes"]
    compatible = Enum.filter(classes, &compatible?(&1, requirement))

    candidates =
      compatible
      |> Enum.filter(&admissible?(&1, requirement["quantity"]))
      |> Enum.map(fn class ->
        %{
          "class" => class["id"],
          "admissible_quantity" => requirement["quantity"],
          "quantities" => %{
            "allocatable" => class["quantities"]["allocatable"],
            "queued" => class["quantities"]["queued"]
          },
          "evidence" => %{
            "freshness" => class["evidence"]["freshness"],
            "age_seconds" => class["evidence"]["age_seconds"]
          },
          "estimate" =>
            Estimate.build(
              class,
              requirement,
              class["quantities"]["queued"],
              class["evidence"]["age_seconds"],
              config
            )
        }
      end)
      |> Enum.sort_by(&sort_key(&1))
      |> Enum.with_index(1)
      |> Enum.map(fn {candidate, rank} -> Map.put(candidate, "rank", rank) end)

    excluded =
      classes
      |> Enum.reject(&Enum.any?(candidates, fn candidate -> candidate["class"] == &1["id"] end))
      |> Enum.map(&exclusion(&1, requirement))

    %{candidates: candidates, excluded: excluded}
  end

  defp compatible?(class, requirement) do
    isolation_compatible?(class["id"], requirement["isolation"]) and
      class["egress"] == requirement["egress"] and
      class["data_location"] == requirement["data_location"] and
      Enum.all?(requirement["tools"], &(&1 in Catalog.get(class["id"])["tools"])) and
      (requirement["target"] == "customer_computer" or not class["explicit_target_only"])
  end

  defp isolation_compatible?("strong", "managed_strong"), do: true
  defp isolation_compatible?("strong", "managed_standard"), do: true
  defp isolation_compatible?(class_id, "managed_standard"), do: class_id in ["standard", "batch"]
  defp isolation_compatible?("connected", "customer_controlled"), do: true
  defp isolation_compatible?(_class_id, _isolation), do: false

  defp admissible?(class, quantity) do
    class["admits"] == true and is_integer(class["quantities"]["allocatable"]) and
      class["quantities"]["allocatable"] >= quantity
  end

  defp exclusion(class, requirement) do
    cond do
      requirement["target"] != "customer_computer" and class["explicit_target_only"] ->
        %{
          "class" => class["id"],
          "code" => "explicit_target_required",
          "detail" => "A connected computer is never an implicit target."
        }

      class["evidence"]["freshness"] == "unavailable" ->
        %{
          "class" => class["id"],
          "code" => "evidence_unavailable",
          "detail" => "The class has no capacity evidence."
        }

      class["evidence"]["freshness"] == "stale" ->
        %{
          "class" => class["id"],
          "code" => "evidence_stale",
          "detail" => "The class capacity evidence is stale."
        }

      class["admits"] == false and class["refusal"]["code"] == "incident_drained" ->
        %{
          "class" => class["id"],
          "code" => "incident_drained",
          "detail" => "The class is incident-drained."
        }

      true ->
        available = class["quantities"]["allocatable"] || 0

        %{
          "class" => class["id"],
          "code" => "quantity_unavailable",
          "detail" =>
            "The class admits #{available} of #{requirement["quantity"]} requested units."
        }
    end
  end

  defp sort_key(candidate) do
    estimate = candidate["estimate"]

    {if(candidate["evidence"]["freshness"] == "fresh", do: 0, else: 1),
     if(candidate["admissible_quantity"] > 0, do: 0, else: 1), estimate["cost"]["low"],
     estimate["completion_seconds"]["low"]}
  end
end
