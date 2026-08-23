defmodule OpenAgents.ArtifactCatalog do
  @moduledoc """
  Publishes safe licensed-artifact projections and append-only transaction evidence.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.ArtifactCatalog.Listing
  alias OpenAgents.ArtifactCatalog.Receipt
  alias OpenAgents.Repo

  @transaction_actions ~w(offer acceptance delivery verification settlement)
  @predecessors %{
    "offer" => "publication",
    "acceptance" => "offer",
    "delivery" => "acceptance",
    "verification" => "delivery",
    "settlement" => "verification"
  }
  @statuses %{
    "offer" => "recorded",
    "acceptance" => "admitted",
    "delivery" => "recorded",
    "verification" => "verified",
    "settlement" => "settled"
  }

  def publish_listing(attributes) when is_map(attributes) do
    changeset = Listing.publication_changeset(%Listing{}, attributes)

    Multi.new()
    |> Multi.insert(:listing, changeset)
    |> Multi.insert(:receipt, fn %{listing: listing} ->
      Receipt.changeset(%Receipt{listing_id: listing.id}, %{
        action: "publication",
        status: "recorded",
        receipt_ref: listing.publication_receipt_ref,
        buyer_ref: listing.buyer_name,
        buyer_class: listing.buyer_class,
        artifact_digest: listing.artifact_digest,
        provenance_digest: listing.provenance_digest,
        license_digest: listing.license_digest,
        listing_digest: listing.listing_digest,
        metadata: %{
          "license_contract_ref" => listing.license_contract_ref,
          "verification_policy" => listing.verification_policy
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{listing: listing}} -> {:ok, listing}
      {:error, :listing, changeset, _changes} -> {:error, changeset}
      {:error, :receipt, changeset, _changes} -> {:error, changeset}
    end
  end

  def list_public_listings(filters \\ %{}) when is_map(filters) do
    now = DateTime.utc_now()

    Listing
    |> where([listing], listing.state == "active")
    |> where([listing], listing.license_effective_at <= ^now)
    |> where([listing], listing.license_expires_at > ^now)
    |> filter_type(filters)
    |> filter_buyer_class(filters)
    |> filter_query(filters)
    |> order_by([listing], desc: listing.evidence_fresh_at, desc: listing.inserted_at)
    |> limit(^limit(filters))
    |> Repo.all()
  end

  def get_public_listing(id) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      now = DateTime.utc_now()

      Listing
      |> where([listing], listing.id == ^id)
      |> where([listing], listing.state == "active")
      |> where([listing], listing.license_effective_at <= ^now)
      |> where([listing], listing.license_expires_at > ^now)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        listing -> {:ok, listing}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def export_public_listing(id) when is_binary(id) do
    with {:ok, listing} <- get_public_listing(id) do
      {:ok,
       %{
         "catalog_version" => 1,
         "exported_at" => DateTime.utc_now(),
         "listing" => Listing.public_projection(listing)
       }}
    end
  end

  def record_transaction(listing_id, action, attributes)
      when is_binary(listing_id) and action in @transaction_actions and is_map(attributes) do
    Repo.transaction(fn ->
      with {:ok, listing} <- get_available_listing_for_update(listing_id),
           :ok <- verify_digest_bindings(listing, attributes),
           {:ok, predecessor} <- verify_predecessor(listing, action, attributes),
           {:ok, receipt} <- insert_transaction_receipt(listing, action, attributes, predecessor) do
        receipt
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def record_transaction(_listing_id, _action, _attributes), do: {:error, :invalid_action}

  def authorize_source_access(listing_id, attributes)
      when is_binary(listing_id) and is_map(attributes) do
    with purpose when purpose in ["delivery", "evaluation"] <- attribute(attributes, :purpose),
         buyer_ref when is_binary(buyer_ref) <- attribute(attributes, :buyer_ref),
         acceptance_ref when is_binary(acceptance_ref) <- attribute(attributes, :acceptance_ref),
         {:ok, listing} <- get_available_listing(listing_id),
         %Receipt{} = acceptance <-
           Repo.get_by(Receipt,
             listing_id: listing.id,
             receipt_ref: acceptance_ref,
             action: "acceptance",
             status: "admitted",
             buyer_ref: buyer_ref
           ),
         :ok <- receipt_matches_listing(acceptance, listing) do
      {:ok,
       %{
         source_ref: listing.source_ref,
         artifact_digest: listing.artifact_digest,
         provenance_digest: listing.provenance_digest,
         license_digest: listing.license_digest,
         purpose: purpose,
         acceptance_ref: acceptance.receipt_ref
       }}
    else
      {:error, reason} -> {:error, reason}
      _not_admitted -> {:error, :not_authorized}
    end
  end

  def remove_listing(listing_id, attributes)
      when is_binary(listing_id) and is_map(attributes) do
    Repo.transaction(fn ->
      with {:ok, listing} <- get_available_listing_for_update(listing_id),
           reason when is_binary(reason) <- attribute(attributes, :reason),
           receipt_ref when is_binary(receipt_ref) <- attribute(attributes, :receipt_ref),
           actor_ref when is_binary(actor_ref) <- attribute(attributes, :actor_ref),
           {:ok, removed} <-
             listing
             |> Listing.removal_changeset(%{
               state: "removed",
               removed_at: DateTime.utc_now(),
               removal_reason: reason
             })
             |> Repo.update(),
           {:ok, _receipt} <-
             insert_removal_receipt(removed, receipt_ref, actor_ref, reason) do
        removed
      else
        {:error, reason} -> Repo.rollback(reason)
        _invalid_attributes -> Repo.rollback(:invalid_removal)
      end
    end)
    |> unwrap_transaction()
  end

  def export_listing_history(listing_id) when is_binary(listing_id) do
    with {:ok, listing_id} <- Ecto.UUID.cast(listing_id) do
      case Repo.get(Listing, listing_id) do
        nil ->
          {:error, :not_found}

        listing ->
          receipts =
            Receipt
            |> where([receipt], receipt.listing_id == ^listing.id)
            |> order_by([receipt], asc: receipt.inserted_at, asc: receipt.id)
            |> Repo.all()
            |> Enum.map(&Receipt.projection/1)

          {:ok,
           %{
             "catalog_version" => 1,
             "exported_at" => DateTime.utc_now(),
             "state" => listing.state,
             "removed_at" => listing.removed_at,
             "listing" => Listing.public_projection(listing),
             "receipts" => receipts
           }}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp get_available_listing(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.get(Listing, id) do
        nil -> {:error, :not_found}
        listing -> validate_available_listing(listing)
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp get_available_listing_for_update(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Listing
      |> where([listing], listing.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        listing -> validate_available_listing(listing)
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp validate_available_listing(%Listing{state: "removed"}), do: {:error, :listing_removed}

  defp validate_available_listing(%Listing{} = listing) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(listing.license_effective_at, now) == :gt -> {:error, :stale_license}
      DateTime.compare(listing.license_expires_at, now) != :gt -> {:error, :stale_license}
      true -> {:ok, listing}
    end
  end

  defp verify_digest_bindings(listing, attributes) do
    expected = %{
      artifact_digest: listing.artifact_digest,
      provenance_digest: listing.provenance_digest,
      license_digest: listing.license_digest,
      listing_digest: listing.listing_digest
    }

    Enum.reduce_while(expected, :ok, fn {field, digest}, :ok ->
      if attribute(attributes, field) == digest do
        {:cont, :ok}
      else
        {:halt, {:error, {:digest_mismatch, field}}}
      end
    end)
  end

  defp verify_predecessor(listing, action, attributes) do
    predecessor_ref = attribute(attributes, :predecessor_ref)
    expected_action = Map.fetch!(@predecessors, action)

    case Repo.get_by(Receipt,
           listing_id: listing.id,
           receipt_ref: predecessor_ref,
           action: expected_action
         ) do
      nil -> {:error, {:invalid_predecessor, expected_action}}
      receipt -> {:ok, receipt}
    end
  end

  defp insert_transaction_receipt(listing, action, attributes, predecessor) do
    buyer_ref = attribute(attributes, :buyer_ref)
    buyer_class = attribute(attributes, :buyer_class)

    cond do
      not is_binary(buyer_ref) ->
        {:error, :invalid_buyer}

      action == "settlement" and not valid_reference?(attribute(attributes, :external_ref)) ->
        {:error, :missing_settlement_reference}

      buyer_class != listing.buyer_class ->
        {:error, :buyer_class_mismatch}

      predecessor.action != "publication" and predecessor.buyer_ref != buyer_ref ->
        {:error, :buyer_mismatch}

      true ->
        %Receipt{listing_id: listing.id}
        |> Receipt.changeset(%{
          action: action,
          status: Map.fetch!(@statuses, action),
          receipt_ref: attribute(attributes, :receipt_ref),
          predecessor_ref: predecessor.receipt_ref,
          external_ref: attribute(attributes, :external_ref),
          buyer_ref: buyer_ref,
          buyer_class: buyer_class,
          artifact_digest: listing.artifact_digest,
          provenance_digest: listing.provenance_digest,
          license_digest: listing.license_digest,
          listing_digest: listing.listing_digest,
          metadata: attribute(attributes, :metadata) || %{}
        })
        |> Repo.insert()
    end
  end

  defp insert_removal_receipt(listing, receipt_ref, actor_ref, reason) do
    predecessor_ref =
      Receipt
      |> where([receipt], receipt.listing_id == ^listing.id)
      |> order_by([receipt], desc: receipt.inserted_at, desc: receipt.id)
      |> select([receipt], receipt.receipt_ref)
      |> limit(1)
      |> Repo.one()

    %Receipt{listing_id: listing.id}
    |> Receipt.changeset(%{
      action: "removal",
      status: "removed",
      receipt_ref: receipt_ref,
      predecessor_ref: predecessor_ref,
      buyer_ref: actor_ref,
      buyer_class: "operator",
      artifact_digest: listing.artifact_digest,
      provenance_digest: listing.provenance_digest,
      license_digest: listing.license_digest,
      listing_digest: listing.listing_digest,
      metadata: %{"reason" => reason}
    })
    |> Repo.insert()
  end

  defp receipt_matches_listing(receipt, listing) do
    if receipt.artifact_digest == listing.artifact_digest and
         receipt.provenance_digest == listing.provenance_digest and
         receipt.license_digest == listing.license_digest and
         receipt.listing_digest == listing.listing_digest do
      :ok
    else
      {:error, :receipt_digest_mismatch}
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp filter_type(query, filters) do
    case attribute(filters, :artifact_type) do
      type when type in ["trace", "dataset"] ->
        where(query, [listing], listing.artifact_type == ^type)

      _other ->
        query
    end
  end

  defp filter_buyer_class(query, filters) do
    case attribute(filters, :buyer_class) do
      buyer_class when is_binary(buyer_class) and buyer_class != "" ->
        where(query, [listing], listing.buyer_class == ^buyer_class)

      _other ->
        query
    end
  end

  defp filter_query(query, filters) do
    case attribute(filters, :q) do
      term when is_binary(term) and term != "" ->
        pattern = "%#{term}%"

        where(
          query,
          [listing],
          ilike(listing.owner_description, ^pattern) or
            ilike(listing.artifact_digest, ^pattern) or
            ilike(listing.buyer_name, ^pattern) or
            ilike(listing.buyer_class, ^pattern)
        )

      _other ->
        query
    end
  end

  defp limit(filters) do
    case attribute(filters, :limit) do
      value when is_integer(value) -> value |> max(1) |> min(100)
      value when is_binary(value) -> parse_limit(value)
      _other -> 50
    end
  end

  defp parse_limit(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer |> max(1) |> min(100)
      _invalid -> 50
    end
  end

  defp valid_reference?(value), do: is_binary(value) and value != ""

  defp attribute(attributes, field) do
    Map.get(attributes, field) || Map.get(attributes, Atom.to_string(field))
  end
end
