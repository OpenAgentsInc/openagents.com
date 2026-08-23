defmodule OpenAgents.Capacity do
  @moduledoc """
  Publishes a bounded, read-only capacity projection and typed matching decisions.

  Managed capacity remains owned by the private broker. Connected-computer
  evidence comes from this application's owner-scoped records.
  """

  alias OpenAgents.Capacity.{Catalog, Connected, Estimate, Math, Matcher, Requirement}
  alias OpenAgents.Machines

  @schema "openagents.capacity.v1"
  @match_schema "openagents.capacity_match.v1"
  @refusal_schema "openagents.capacity_refusal.v1"

  @spec projection(map()) :: map()
  def projection(viewer) do
    config = config()
    broker = fetch_broker(config, viewer)
    connected = fetch_connected(viewer)
    evidence = merge_evidence(broker, connected)
    generated_at = now()

    classes =
      Catalog.all()
      |> Enum.flat_map(fn catalog ->
        case Map.get(evidence, catalog["id"]) do
          :private -> []
          raw -> [class_projection(catalog, raw, config)]
        end
      end)

    %{
      "schema" => @schema,
      "generated_at" => generated_at,
      "limits" => %{
        "reserved_headroom_fraction" => Keyword.get(config, :reserved_headroom_fraction, 0.25),
        "active_per_conversation" => Keyword.get(config, :active_per_conversation, 4),
        "logical_per_conversation" => Keyword.get(config, :logical_per_conversation, 30)
      },
      "classes" => classes
    }
  end

  @spec match(map(), map()) :: {:ok, map()} | {:error, map()}
  def match(viewer, raw_requirement) do
    config = config()

    with {:ok, requirement} <- normalize_requirement(raw_requirement),
         :ok <- verify_tools(requirement),
         :ok <- verify_target(viewer, requirement),
         :ok <- verify_budget(requirement, config) do
      projection = projection(viewer)
      result = Matcher.match(projection, requirement, config)

      if result.candidates == [] do
        {:error, refusal_for(result.excluded)}
      else
        {:ok,
         %{
           "schema" => @match_schema,
           "generated_at" => projection["generated_at"],
           "requirement" => requirement,
           "candidates" => result.candidates,
           "excluded" => result.excluded
         }}
      end
    else
      {:error, code, detail} -> {:error, refusal(code, detail)}
    end
  end

  def refusal_schema, do: @refusal_schema

  defp normalize_requirement(raw_requirement) do
    case Requirement.normalize(raw_requirement) do
      {:ok, requirement} -> {:ok, requirement}
      {:error, code, detail} -> {:error, code, detail}
    end
  end

  defp verify_tools(requirement) do
    if Enum.all?(requirement["tools"], fn tool ->
         Enum.any?(Catalog.all(), &(tool in &1["tools"]))
       end) do
      :ok
    else
      {:error, :unsupported_tool, "No admitted class supports every requested tool."}
    end
  end

  defp verify_target(_viewer, %{"target" => "openagents_managed"}), do: :ok

  defp verify_target(%{id: user_id}, %{"target" => "customer_computer", "computer_id" => id}) do
    case Machines.get_machine(user_id, id) do
      {:ok, _machine} ->
        :ok

      {:error, :machine_not_found} ->
        {:error, :computer_not_found, "The named computer is not yours."}
    end
  end

  defp verify_target(_viewer, _requirement),
    do:
      {:error, :explicit_target_required,
       "A customer computer target requires an owned computer_id."}

  defp verify_budget(%{"budget" => nil}, _config), do: :ok

  defp verify_budget(requirement, config) do
    compatible =
      Catalog.all()
      |> Enum.filter(fn class ->
        compatible_isolation?(class["id"], requirement["isolation"]) and
          class["egress"] == requirement["egress"] and
          class["data_location"] == requirement["data_location"] and
          Enum.all?(requirement["tools"], &(&1 in class["tools"]))
      end)

    minimum =
      compatible
      |> Enum.map(&Estimate.unit_cost(&1["id"], config))
      |> Enum.min(fn -> 0 end)
      |> then(&ceil(&1 * requirement["quantity"] * requirement["duration_seconds"] / 3_600))

    if requirement["budget"]["amount"] < minimum do
      {:error, :budget_below_minimum,
       "The budget cannot cover one admitted class for the requested duration."}
    else
      :ok
    end
  end

  defp compatible_isolation?("strong", isolation)
       when isolation in ["managed_standard", "managed_strong"],
       do: true

  defp compatible_isolation?(class_id, "managed_standard") when class_id in ["standard", "batch"],
    do: true

  defp compatible_isolation?("connected", "customer_controlled"), do: true
  defp compatible_isolation?(_class_id, _isolation), do: false

  defp refusal_for([]),
    do: refusal(:quantity_unavailable, "No admitted class can satisfy the requested quantity.")

  defp refusal_for(excluded) do
    codes =
      excluded
      |> Enum.reject(&(&1["code"] == "explicit_target_required"))
      |> Enum.map(& &1["code"])

    code =
      cond do
        "incident_drained" in codes -> :incident_drained
        "evidence_stale" in codes -> :evidence_stale
        "quantity_unavailable" in codes -> :quantity_unavailable
        "evidence_unavailable" in codes -> :evidence_unavailable
        true -> :quantity_unavailable
      end

    detail =
      excluded
      |> Enum.find(&(&1["code"] == Atom.to_string(code)))
      |> case do
        %{"detail" => detail} -> detail
        nil -> "No admitted class can satisfy the requested requirement."
      end

    refusal(code, detail)
  end

  defp refusal(code, detail) when is_atom(code),
    do: %{
      "schema" => @refusal_schema,
      "error" => %{"code" => Atom.to_string(code), "detail" => detail}
    }

  defp class_projection(catalog, :unavailable, _config),
    do: unavailable_class(catalog, "evidence_unavailable")

  defp class_projection(catalog, nil, _config),
    do: unavailable_class(catalog, "evidence_unavailable")

  defp class_projection(catalog, raw, config) when is_map(raw) do
    quantities = Math.quantities(catalog, raw, config)
    observed_at = parse_datetime(raw["observed_at"])
    age_seconds = age_seconds(observed_at)
    maximum_age = Keyword.get(config, :maximum_evidence_age_seconds, 120)
    freshness = freshness(observed_at, age_seconds, maximum_age)
    incident_drained = raw["incident_drained"] == true

    refusal_code =
      cond do
        freshness == "unavailable" -> "evidence_unavailable"
        freshness == "stale" -> "evidence_stale"
        incident_drained -> "incident_drained"
        true -> nil
      end

    quantities =
      if freshness == "stale" do
        Map.put(quantities, "allocatable", 0)
      else
        quantities
      end

    %{
      "id" => catalog["id"],
      "label" => catalog["label"],
      "isolation" => catalog["isolation"],
      "egress" => catalog["egress"],
      "data_location" => catalog["data_location"],
      "explicit_target_only" => catalog["explicit_target_only"],
      "unit" => catalog["unit"],
      "quantities" => quantities,
      "queue" => %{
        "queued" => quantities["queued"],
        "estimated_wait_seconds" => safe_wait(raw["estimated_wait_seconds"])
      },
      "evidence" => %{
        "source" => if(catalog["id"] == "connected", do: "local", else: "broker"),
        "observed_at" => raw["observed_at"],
        "age_seconds" => age_seconds,
        "maximum_age_seconds" => maximum_age,
        "freshness" => freshness
      },
      "admits" => freshness == "fresh" and not incident_drained,
      "refusal" => if(refusal_code, do: %{"code" => refusal_code}, else: nil)
    }
  end

  defp unavailable_class(catalog, code) do
    %{
      "id" => catalog["id"],
      "label" => catalog["label"],
      "isolation" => catalog["isolation"],
      "egress" => catalog["egress"],
      "data_location" => catalog["data_location"],
      "explicit_target_only" => catalog["explicit_target_only"],
      "unit" => catalog["unit"],
      "quantities" => %{
        "logical" => nil,
        "active_reservations" => nil,
        "allocatable" => nil,
        "queued" => nil,
        "safety_headroom" => nil,
        "configured_ceiling" => nil,
        "observed_limit" => nil
      },
      "queue" => %{"queued" => nil, "estimated_wait_seconds" => nil},
      "evidence" => %{
        "source" => if(catalog["id"] == "connected", do: "local", else: "broker"),
        "observed_at" => nil,
        "age_seconds" => nil,
        "maximum_age_seconds" => Keyword.get(config(), :maximum_evidence_age_seconds, 120),
        "freshness" => "unavailable"
      },
      "admits" => false,
      "refusal" => %{"code" => code}
    }
  end

  defp fetch_broker(config, viewer) do
    source = Keyword.get(config, :evidence_source, OpenAgents.Capacity.Broker)

    result =
      try do
        Code.ensure_loaded(source)

        cond do
          function_exported?(source, :fetch, 1) -> source.fetch(viewer)
          function_exported?(source, :read, 1) -> source.read(viewer)
          true -> {:error, :evidence_unavailable}
        end
      rescue
        _error -> {:error, :evidence_unavailable}
      end

    case result do
      {:ok, %{"classes" => classes}} when is_list(classes) ->
        Enum.reduce(classes, %{}, fn raw, acc ->
          if is_map(raw) and is_binary(raw["id"]) do
            Map.put(acc, raw["id"], if(raw["private"] == true, do: :private, else: raw))
          else
            acc
          end
        end)

      classes when is_map(classes) ->
        classes

      _error ->
        %{}
    end
  end

  defp fetch_connected(viewer) do
    case Connected.fetch(viewer) do
      {:ok, %{"classes" => [raw | _]}} -> %{"connected" => raw}
      _error -> %{}
    end
  end

  defp merge_evidence(broker, connected), do: Map.merge(broker, connected)

  defp config, do: Application.get_env(:openagents, OpenAgents.Capacity, [])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value
  defp parse_datetime(_invalid), do: nil

  defp age_seconds(nil), do: nil
  defp age_seconds(datetime), do: max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

  defp freshness(nil, _age, _maximum), do: "unavailable"
  defp freshness(_datetime, age, maximum) when age <= maximum, do: "fresh"
  defp freshness(_datetime, _age, _maximum), do: "stale"

  defp safe_wait(%{"low" => low, "high" => high})
       when is_integer(low) and low >= 0 and is_integer(high) and high >= low,
       do: %{"low" => low, "high" => high}

  defp safe_wait(_invalid), do: nil
end
