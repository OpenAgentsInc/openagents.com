defmodule OpenAgents.ArtifactCatalogFixtures do
  @moduledoc false

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.Provenance.Canonical

  def listing_attributes(overrides \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now()

    Map.merge(
      %{
        artifact_type: "dataset",
        owner_ref: "owner:openagents",
        owner_description: "Redacted support traces for tool-selection evaluation #{suffix}",
        source_ref: "vault://artifact-catalog/#{suffix}",
        artifact_digest: Canonical.sha256("artifact-#{suffix}"),
        provenance_digest: Canonical.sha256("provenance-#{suffix}"),
        provenance: %{
          "origin_class" => "consented support trace",
          "transformation_receipts" => ["redaction:#{suffix}"]
        },
        schema: %{
          "name" => "openagents.trace",
          "version" => "1",
          "format" => "jsonl"
        },
        size_bytes: 24_000,
        record_count: 120,
        coverage: %{
          "domains" => ["tool selection"],
          "languages" => ["en"],
          "record_types" => ["trace"]
        },
        redaction: %{
          "policy" => "support-trace-v1",
          "removed_fields" => ["account identifiers", "message source references"],
          "irreversible" => true
        },
        license_contract_ref: "license:opt-in:#{suffix}",
        license_terms: %{
          "opt_in" => true,
          "allowed_uses" => ["evaluation", "training"],
          "redistribution" => "prohibited"
        },
        license_effective_at: DateTime.add(now, -60, :second),
        license_expires_at: DateTime.add(now, 86_400, :second),
        price: %{
          "amount" => 25,
          "currency" => "USD",
          "unit" => "evaluation"
        },
        buyer_name: "OpenAgents continual-learning program",
        buyer_class: "openagents_training",
        verification_policy: %{
          "method" => "exact digest plus schema checks",
          "required_checks" => ["artifact_digest", "provenance_digest", "schema"],
          "policy_ref" => "verification:artifact-v1"
        },
        evidence_fresh_at: DateTime.add(now, -30, :second),
        publication_receipt_ref: "artifact-publication:#{suffix}"
      },
      overrides
    )
  end

  def publish_listing!(overrides \\ %{}) do
    {:ok, listing} =
      overrides
      |> listing_attributes()
      |> ArtifactCatalog.publish_listing()

    listing
  end

  def transaction_attributes(listing, predecessor_ref, overrides \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic])

    Map.merge(
      %{
        receipt_ref: "artifact-transaction:#{suffix}",
        predecessor_ref: predecessor_ref,
        external_ref: "external-evidence:#{suffix}",
        buyer_ref: "buyer:openagents",
        buyer_class: listing.buyer_class,
        artifact_digest: listing.artifact_digest,
        provenance_digest: listing.provenance_digest,
        license_digest: listing.license_digest,
        listing_digest: listing.listing_digest,
        metadata: %{"operator_receipt_ref" => "operator:#{suffix}"}
      },
      overrides
    )
  end
end
