defmodule OpenAgents.ArtifactCatalogTest do
  use OpenAgents.DataCase, async: true

  import OpenAgents.ArtifactCatalogFixtures

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.ArtifactCatalog.Listing
  alias OpenAgents.ArtifactCatalog.Receipt
  alias OpenAgents.Repo

  test "publishes and discovers an exact safe projection" do
    attributes = listing_attributes()
    assert {:ok, listing} = ArtifactCatalog.publish_listing(attributes)

    assert [^listing] = ArtifactCatalog.list_public_listings()
    assert byte_size(listing.license_digest) == 64
    assert byte_size(listing.listing_digest) == 64

    projection = Listing.public_projection(listing)
    refute Map.has_key?(projection, "source_ref")
    refute inspect(projection) =~ attributes.source_ref
    assert projection["artifact_digest"] == attributes.artifact_digest
    assert projection["provenance"]["digest"] == attributes.provenance_digest
    assert projection["buyer"]["name"] == "OpenAgents continual-learning program"
    assert projection["verification_policy"]["policy_ref"] == "verification:artifact-v1"
  end

  test "searches compatible listings by text, type, buyer class, and digest" do
    matching =
      publish_listing!(%{
        artifact_type: "trace",
        owner_description: "Browser navigation trace",
        buyer_class: "openagents_evaluation"
      })

    _other = publish_listing!(%{owner_description: "Database query dataset"})

    assert [^matching] = ArtifactCatalog.list_public_listings(%{"q" => "navigation"})
    assert [^matching] = ArtifactCatalog.list_public_listings(%{"artifact_type" => "trace"})

    assert [^matching] =
             ArtifactCatalog.list_public_listings(%{"buyer_class" => "openagents_evaluation"})

    assert [^matching] =
             ArtifactCatalog.list_public_listings(%{
               "q" => binary_part(matching.artifact_digest, 0, 20)
             })
  end

  test "requires explicit opt-in and rejects private source metadata" do
    no_opt_in =
      listing_attributes(%{
        license_terms: %{"opt_in" => false, "allowed_uses" => ["evaluation"]}
      })

    assert {:error, changeset} = ArtifactCatalog.publish_listing(no_opt_in)
    assert "must record explicit opt-in" in errors_on(changeset).license_terms

    private_projection =
      listing_attributes(%{
        coverage: %{"domains" => ["tool selection"], "source_uri" => "s3://private/source"}
      })

    assert {:error, changeset} = ArtifactCatalog.publish_listing(private_projection)
    assert "contains private source metadata" in errors_on(changeset).coverage
  end

  test "binds a supplied listing identity to canonical license and listing digests" do
    assert {:error, changeset} =
             listing_attributes(%{license_digest: String.duplicate("f", 64)})
             |> ArtifactCatalog.publish_listing()

    assert "does not match the canonical identity" in errors_on(changeset).license_digest

    assert {:error, changeset} =
             listing_attributes(%{listing_digest: String.duplicate("e", 64)})
             |> ArtifactCatalog.publish_listing()

    assert "does not match the canonical identity" in errors_on(changeset).listing_digest
  end

  test "admits source access only after an accepted delivery or evaluation flow" do
    listing = publish_listing!()

    assert {:error, :not_authorized} =
             ArtifactCatalog.authorize_source_access(listing.id, %{
               purpose: "evaluation",
               buyer_ref: "buyer:openagents",
               acceptance_ref: "missing"
             })

    assert {:ok, offer} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "offer",
               transaction_attributes(listing, listing.publication_receipt_ref)
             )

    assert {:ok, acceptance} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "acceptance",
               transaction_attributes(listing, offer.receipt_ref)
             )

    assert {:error, :not_authorized} =
             ArtifactCatalog.authorize_source_access(listing.id, %{
               purpose: "evaluation",
               buyer_ref: "buyer:other",
               acceptance_ref: acceptance.receipt_ref
             })

    assert {:ok, authorization} =
             ArtifactCatalog.authorize_source_access(listing.id, %{
               purpose: "evaluation",
               buyer_ref: "buyer:openagents",
               acceptance_ref: acceptance.receipt_ref
             })

    assert authorization.source_ref == listing.source_ref
    assert authorization.artifact_digest == listing.artifact_digest
  end

  test "rejects delivery when any accepted digest changes" do
    listing = publish_listing!()

    assert {:ok, offer} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "offer",
               transaction_attributes(listing, listing.publication_receipt_ref)
             )

    assert {:ok, acceptance} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "acceptance",
               transaction_attributes(listing, offer.receipt_ref)
             )

    mismatched =
      transaction_attributes(listing, acceptance.receipt_ref, %{
        artifact_digest: String.duplicate("0", 64)
      })

    assert {:error, {:digest_mismatch, :artifact_digest}} =
             ArtifactCatalog.record_transaction(listing.id, "delivery", mismatched)

    refute Repo.get_by(Receipt, listing_id: listing.id, action: "delivery")
  end

  test "records the bounded transaction chain without settling funds" do
    listing = publish_listing!()

    receipts =
      Enum.reduce(
        ~w(offer acceptance delivery verification settlement),
        {listing.publication_receipt_ref, []},
        fn action, {predecessor_ref, receipts} ->
          assert {:ok, receipt} =
                   ArtifactCatalog.record_transaction(
                     listing.id,
                     action,
                     transaction_attributes(listing, predecessor_ref)
                   )

          {receipt.receipt_ref, [receipt | receipts]}
        end
      )
      |> elem(1)
      |> Enum.reverse()

    assert Enum.map(receipts, & &1.action) ==
             ~w(offer acceptance delivery verification settlement)

    settlement = List.last(receipts)
    assert settlement.status == "settled"
    refute Map.has_key?(settlement.metadata, "amount")
  end

  test "requires an external settlement receipt reference" do
    listing = publish_listing!()

    predecessor_ref =
      Enum.reduce(~w(offer acceptance delivery verification), listing.publication_receipt_ref, fn
        action, predecessor_ref ->
          assert {:ok, receipt} =
                   ArtifactCatalog.record_transaction(
                     listing.id,
                     action,
                     transaction_attributes(listing, predecessor_ref)
                   )

          receipt.receipt_ref
      end)

    assert {:error, :missing_settlement_reference} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "settlement",
               transaction_attributes(listing, predecessor_ref, %{external_ref: nil})
             )
  end

  test "removal blocks discovery and new transactions while preserving receipts" do
    listing = publish_listing!()

    assert {:ok, offer} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "offer",
               transaction_attributes(listing, listing.publication_receipt_ref)
             )

    assert {:ok, removed} =
             ArtifactCatalog.remove_listing(listing.id, %{
               reason: "Owner withdrew this artifact",
               receipt_ref: "artifact-removal:test",
               actor_ref: "operator:test"
             })

    assert removed.state == "removed"
    assert {:error, :not_found} = ArtifactCatalog.get_public_listing(listing.id)
    assert ArtifactCatalog.list_public_listings() == []

    assert {:error, :listing_removed} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "acceptance",
               transaction_attributes(listing, offer.receipt_ref)
             )

    assert {:ok, history} = ArtifactCatalog.export_listing_history(listing.id)
    assert history["state"] == "removed"

    assert Enum.map(history["receipts"], & &1["action"]) ==
             ~w(publication offer removal)
  end

  test "a stale license blocks discovery and new transactions" do
    listing = publish_listing!()

    listing
    |> Ecto.Changeset.change(license_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :not_found} = ArtifactCatalog.get_public_listing(listing.id)
    assert ArtifactCatalog.list_public_listings() == []

    assert {:error, :stale_license} =
             ArtifactCatalog.record_transaction(
               listing.id,
               "offer",
               transaction_attributes(listing, listing.publication_receipt_ref)
             )
  end
end
