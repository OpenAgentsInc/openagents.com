defmodule OpenAgents.Modules.Metadata do
  @moduledoc "Builders for explicit, policy-complete module lifecycle metadata."

  alias OpenAgents.Provenance.Canonical

  @spec first_party(String.t(), String.t(), keyword()) :: map()
  def first_party(authority, data_scope, options \\ []) do
    effect = Keyword.fetch!(options, :effect)
    privacy = Keyword.fetch!(options, :privacy)
    residency = Keyword.fetch!(options, :residency)
    surfaces = Keyword.get(options, :surfaces, ["text", "voice"])

    approval_class =
      Keyword.get(
        options,
        :approval_class,
        if(effect == :read_only, do: "host_policy", else: "exact_current_user_consent")
      )

    %{
      "state" => "admitted",
      "approval_class" => approval_class,
      "capability_scopes" => [authority],
      "data_scopes" => [data_scope],
      "facets" => %{
        "cost" => "included_first_party",
        "cost_units" => 0,
        "quality" => "host_validated",
        "residency" => residency,
        "privacy" => privacy,
        "jurisdiction" => "operator_unspecified",
        "censorship_resistance" => "not_claimed",
        "surfaces" => Enum.sort(Enum.uniq(surfaces)),
        "approval_enforcement" =>
          Keyword.get(
            options,
            :approval_enforcement,
            if(effect == :read_only, do: "host_receipt", else: "executor_consent")
          )
      },
      "publisher" => "OpenAgentsInc",
      "provenance" => %{
        "source" => "https://github.com/OpenAgentsInc/sarah",
        "admission" => "reviewed_first_party_release"
      },
      "compatibility" => %{
        "runtime_min" => 1,
        "runtime_max" => 1,
        "dependencies" => []
      },
      "predecessor" => nil,
      "deprecation" => nil,
      "rollback" => %{"strategy" => "disable_or_restore_predecessor"},
      "attribution_policy" => attribution_policy()
    }
  end

  defp attribution_policy do
    policy = %{
      "id" => "sarah.attribution.deterministic_receipts.v1",
      "version" => 1,
      "mode" => "deterministic_receipt_refs",
      "required" => true
    }

    Map.put(policy, "digest", Canonical.digest!(policy))
  end
end
