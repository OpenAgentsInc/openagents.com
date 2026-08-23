defmodule OpenAgents.CapacityTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Capacity
  alias OpenAgents.Capacity.Math

  setup do
    original_capacity = Application.get_env(:openagents, OpenAgents.Capacity, [])
    original_evidence = Application.get_env(:openagents, :capacity_test_evidence)

    Application.put_env(
      :openagents,
      OpenAgents.Capacity,
      Keyword.merge(original_capacity, evidence_source: OpenAgents.CapacityEvidenceStub)
    )

    on_exit(fn ->
      Application.put_env(:openagents, OpenAgents.Capacity, original_capacity)

      if is_nil(original_evidence) do
        Application.delete_env(:openagents, :capacity_test_evidence)
      else
        Application.put_env(:openagents, :capacity_test_evidence, original_evidence)
      end
    end)

    :ok
  end

  test "caps limit-derived capacity with already-free broker evidence" do
    config = [
      class_ceilings: %{"standard" => 16},
      reserved_headroom_fraction: 0.25
    ]

    quantities =
      Math.quantities(
        %{"id" => "standard"},
        %{
          "logical" => 30,
          "active_reservations" => 4,
          "observed_limit" => 24,
          "reported_free" => 8
        },
        config
      )

    assert quantities["allocatable"] == 8
    assert quantities["safety_headroom"] == 6
  end

  test "publishes fresh and stale evidence without inventing unavailable quantities" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok,
       %{
         "classes" => [
           %{
             "id" => "standard",
             "logical" => 30,
             "active_reservations" => 4,
             "observed_limit" => 24,
             "reported_free" => 8,
             "queued" => 2,
             "observed_at" => DateTime.to_iso8601(now)
           },
           %{
             "id" => "strong",
             "logical" => 2,
             "active_reservations" => 0,
             "observed_limit" => 2,
             "reported_free" => 2,
             "observed_at" => DateTime.to_iso8601(DateTime.add(now, -121, :second))
           },
           %{"id" => "batch", "private" => true}
         ]
       }}
    )

    projection = Capacity.projection(%{id: Ecto.UUID.generate()})
    standard = Enum.find(projection["classes"], &(&1["id"] == "standard"))
    strong = Enum.find(projection["classes"], &(&1["id"] == "strong"))

    assert standard["admits"] == true
    assert standard["quantities"]["allocatable"] == 8
    assert strong["admits"] == false
    assert strong["quantities"]["allocatable"] == 0
    assert strong["refusal"]["code"] == "evidence_stale"
    refute Enum.any?(projection["classes"], &(&1["id"] == "batch"))
  end

  test "returns a typed refusal and never includes broker-only sensitive fields" do
    secret = "project-123 eu-west-1 host.example 192.0.2.1 secret-token image/path"

    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok,
       %{
         "classes" => [
           %{
             "id" => "standard",
             "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
             "observed_limit" => 0,
             "reported_free" => 0,
             "logical" => 0,
             "active_reservations" => 0,
             "provider" => secret,
             "project_id" => secret,
             "region" => secret,
             "zone" => secret,
             "hostname" => secret,
             "guest_ip" => secret,
             "credentials" => secret,
             "image_path" => secret,
             "raw_error" => secret
           }
         ]
       }}
    )

    projection = Capacity.projection(%{id: Ecto.UUID.generate()})
    serialized = Jason.encode!(projection)

    refute serialized =~ secret
    refute serialized =~ "project_id"

    assert projection["classes"] |> Enum.find(&(&1["id"] == "standard")) |> Map.get("admits") ==
             true

    assert {:error, %{"error" => %{"code" => "quantity_unavailable"}}} =
             Capacity.match(
               %{id: Ecto.UUID.generate()},
               %{
                 "quantity" => 1,
                 "isolation" => "managed_standard",
                 "egress" => "policy_broker",
                 "data_location" => "openagents_managed"
               }
             )
  end

  test "managed matching never falls back to connected computers" do
    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok,
       %{
         "classes" => [
           %{
             "id" => "standard",
             "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
             "observed_limit" => 0,
             "reported_free" => 0,
             "logical" => 0,
             "active_reservations" => 0
           }
         ]
       }}
    )

    assert {:error, %{"error" => %{"code" => "quantity_unavailable"}}} =
             Capacity.match(
               %{id: Ecto.UUID.generate()},
               %{
                 "quantity" => 1,
                 "isolation" => "managed_standard",
                 "egress" => "policy_broker",
                 "data_location" => "openagents_managed"
               }
             )
  end

  test "managed standard matching can rank strong runtimes" do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok,
       %{
         "classes" => [
           %{
             "id" => "strong",
             "observed_at" => now,
             "observed_limit" => 2,
             "reported_free" => 2,
             "logical" => 2,
             "active_reservations" => 0
           }
         ]
       }}
    )

    assert {:ok, %{"candidates" => [%{"class" => "strong"}]}} =
             Capacity.match(
               %{id: Ecto.UUID.generate()},
               %{
                 "quantity" => 1,
                 "isolation" => "managed_standard",
                 "egress" => "policy_broker",
                 "data_location" => "openagents_managed"
               }
             )
  end

  test "unsupported requirement fields and budget return typed refusals" do
    viewer = %{id: Ecto.UUID.generate()}

    for {field, value, code} <- [
          {"egress", "private_network", "unsupported_egress"},
          {"data_location", "restricted_zone", "unsupported_data_location"},
          {"tools", ["unsupported_tool"], "unsupported_tool"}
        ] do
      requirement = %{
        "isolation" => "managed_standard",
        "egress" => "policy_broker",
        "data_location" => "openagents_managed"
      }

      requirement =
        if field == "tools" do
          Map.put(requirement, field, value)
        else
          Map.put(requirement, field, value)
        end

      assert {:error, %{"error" => %{"code" => ^code}}} =
               Capacity.match(viewer, requirement)
    end

    assert {:error, %{"error" => %{"code" => "budget_below_minimum"}}} =
             Capacity.match(viewer, %{
               "isolation" => "managed_standard",
               "egress" => "policy_broker",
               "data_location" => "openagents_managed",
               "budget" => %{"currency" => "usd_cents", "amount" => 0}
             })
  end

  test "a customer computer target requires ownership" do
    assert {:error, %{"error" => %{"code" => "computer_not_found"}}} =
             Capacity.match(
               %{id: Ecto.UUID.generate()},
               %{
                 "isolation" => "customer_controlled",
                 "egress" => "customer_network",
                 "data_location" => "customer_premises",
                 "target" => "customer_computer",
                 "computer_id" => Ecto.UUID.generate()
               }
             )
  end

  test "incident-drained and exhausted classes expose refusal evidence" do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok,
       %{
         "classes" => [
           %{
             "id" => "standard",
             "observed_at" => now,
             "observed_limit" => 16,
             "reported_free" => 0,
             "logical" => 16,
             "active_reservations" => 16,
             "queued" => 5
           },
           %{
             "id" => "batch",
             "observed_at" => now,
             "observed_limit" => 8,
             "reported_free" => 8,
             "logical" => 8,
             "active_reservations" => 0,
             "incident_drained" => true
           }
         ]
       }}
    )

    projection = Capacity.projection(%{id: Ecto.UUID.generate()})
    standard = Enum.find(projection["classes"], &(&1["id"] == "standard"))
    batch = Enum.find(projection["classes"], &(&1["id"] == "batch"))

    assert standard["quantities"]["allocatable"] == 0
    assert standard["quantities"]["queued"] == 5
    assert standard["admits"] == true
    assert batch["admits"] == false
    assert batch["refusal"]["code"] == "incident_drained"
  end
end
