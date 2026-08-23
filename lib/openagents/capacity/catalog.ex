defmodule OpenAgents.Capacity.Catalog do
  @moduledoc false

  @classes [
    %{
      "id" => "standard",
      "label" => "Standard",
      "isolation" => "managed_standard",
      "egress" => "policy_broker",
      "data_location" => "openagents_managed",
      "explicit_target_only" => false,
      "unit" => %{"vcpu" => 1, "memory_gib" => 2, "scratch_gib" => 20},
      "tools" => ["shell", "coding_agent"]
    },
    %{
      "id" => "strong",
      "label" => "Strong",
      "isolation" => "managed_strong",
      "egress" => "policy_broker",
      "data_location" => "openagents_managed",
      "explicit_target_only" => false,
      "unit" => %{"vcpu" => 2, "memory_gib" => 4, "scratch_gib" => 40},
      "tools" => ["shell", "coding_agent"]
    },
    %{
      "id" => "batch",
      "label" => "Batch",
      "isolation" => "managed_standard",
      "egress" => "policy_broker",
      "data_location" => "openagents_managed",
      "explicit_target_only" => false,
      "unit" => %{"vcpu" => 1, "memory_gib" => 2, "scratch_gib" => 20},
      "tools" => ["shell", "coding_agent"]
    },
    %{
      "id" => "connected",
      "label" => "Connected",
      "isolation" => "customer_controlled",
      "egress" => "customer_network",
      "data_location" => "customer_premises",
      "explicit_target_only" => true,
      "unit" => %{"vcpu" => nil, "memory_gib" => nil, "scratch_gib" => nil},
      "tools" => ["shell", "coding_agent"]
    }
  ]

  def all, do: @classes

  def get(id), do: Enum.find(@classes, &(&1["id"] == id))
end
