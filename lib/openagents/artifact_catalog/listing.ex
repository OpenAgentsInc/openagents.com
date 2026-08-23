defmodule OpenAgents.ArtifactCatalog.Listing do
  @moduledoc "A safe catalog projection for a licensed trace or dataset."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Provenance.Canonical

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @private_keys ~w(
    email message_id private_source_ref raw_source secret source_path source_ref source_uri token
    user_id
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "verified_artifact_listings" do
    field :artifact_type, :string
    field :state, :string, default: "active"
    field :owner_ref, :string
    field :owner_description, :string
    field :source_ref, :string
    field :artifact_digest, :string
    field :provenance_digest, :string
    field :provenance, :map, default: %{}
    field :schema, :map, default: %{}
    field :size_bytes, :integer
    field :record_count, :integer
    field :coverage, :map, default: %{}
    field :redaction, :map, default: %{}
    field :license_contract_ref, :string
    field :license_terms, :map, default: %{}
    field :license_digest, :string
    field :license_effective_at, :utc_datetime_usec
    field :license_expires_at, :utc_datetime_usec
    field :price, :map, default: %{}
    field :buyer_name, :string
    field :buyer_class, :string
    field :verification_policy, :map, default: %{}
    field :evidence_fresh_at, :utc_datetime_usec
    field :listing_digest, :string
    field :publication_receipt_ref, :string
    field :removed_at, :utc_datetime_usec
    field :removal_reason, :string

    has_many :receipts, OpenAgents.ArtifactCatalog.Receipt
    timestamps()
  end

  @type t :: %__MODULE__{}

  def publication_changeset(listing, attributes) do
    listing
    |> cast(attributes, [
      :artifact_type,
      :owner_ref,
      :owner_description,
      :source_ref,
      :artifact_digest,
      :provenance_digest,
      :provenance,
      :schema,
      :size_bytes,
      :record_count,
      :coverage,
      :redaction,
      :license_contract_ref,
      :license_terms,
      :license_effective_at,
      :license_expires_at,
      :price,
      :buyer_name,
      :buyer_class,
      :verification_policy,
      :evidence_fresh_at,
      :publication_receipt_ref
    ])
    |> validate_required([
      :artifact_type,
      :owner_ref,
      :owner_description,
      :source_ref,
      :artifact_digest,
      :provenance_digest,
      :provenance,
      :schema,
      :size_bytes,
      :coverage,
      :redaction,
      :license_contract_ref,
      :license_terms,
      :license_effective_at,
      :license_expires_at,
      :buyer_name,
      :buyer_class,
      :verification_policy,
      :evidence_fresh_at,
      :publication_receipt_ref
    ])
    |> validate_inclusion(:artifact_type, ~w(trace dataset))
    |> validate_format(:artifact_digest, @digest_regex)
    |> validate_format(:provenance_digest, @digest_regex)
    |> validate_number(:size_bytes, greater_than: 0)
    |> validate_number(:record_count, greater_than: 0)
    |> validate_length(:owner_ref, min: 1, max: 256)
    |> validate_length(:owner_description, min: 1, max: 2_000)
    |> validate_length(:source_ref, min: 1, max: 1_000)
    |> validate_length(:license_contract_ref, min: 1, max: 256)
    |> validate_length(:buyer_name, min: 1, max: 256)
    |> validate_length(:buyer_class, min: 1, max: 128)
    |> validate_length(:publication_receipt_ref, min: 1, max: 256)
    |> validate_safe_map(:provenance)
    |> validate_safe_map(:schema)
    |> validate_safe_map(:coverage)
    |> validate_safe_map(:redaction)
    |> validate_safe_map(:license_terms)
    |> validate_safe_map(:price)
    |> validate_safe_map(:verification_policy)
    |> validate_opt_in_license()
    |> validate_license_window()
    |> validate_active_license()
    |> put_identity_digests(attributes)
    |> unique_constraint([:artifact_digest, :provenance_digest, :license_digest],
      name: :verified_artifact_listings_identity_index
    )
    |> unique_constraint(:listing_digest)
    |> unique_constraint(:publication_receipt_ref)
  end

  def removal_changeset(listing, attributes) do
    listing
    |> change(attributes)
    |> validate_required([:state, :removed_at, :removal_reason])
    |> validate_inclusion(:state, ["removed"])
    |> validate_length(:removal_reason, min: 1, max: 1_000)
  end

  def public_projection(%__MODULE__{} = listing) do
    %{
      "id" => listing.id,
      "artifact_type" => listing.artifact_type,
      "owner" => %{
        "ref" => listing.owner_ref,
        "description" => listing.owner_description
      },
      "artifact_digest" => listing.artifact_digest,
      "provenance" => Map.put(listing.provenance, "digest", listing.provenance_digest),
      "schema" => listing.schema,
      "size" => %{
        "bytes" => listing.size_bytes,
        "records" => listing.record_count
      },
      "coverage" => listing.coverage,
      "redaction" => listing.redaction,
      "license" => %{
        "contract_ref" => listing.license_contract_ref,
        "digest" => listing.license_digest,
        "terms" => listing.license_terms,
        "effective_at" => listing.license_effective_at,
        "expires_at" => listing.license_expires_at
      },
      "price" => listing.price,
      "buyer" => %{
        "name" => listing.buyer_name,
        "class" => listing.buyer_class
      },
      "verification_policy" => listing.verification_policy,
      "evidence_fresh_at" => listing.evidence_fresh_at,
      "listing_digest" => listing.listing_digest,
      "publication_receipt_ref" => listing.publication_receipt_ref,
      "published_at" => listing.inserted_at
    }
  end

  defp validate_license_window(changeset) do
    effective_at = get_field(changeset, :license_effective_at)
    expires_at = get_field(changeset, :license_expires_at)
    evidence_fresh_at = get_field(changeset, :evidence_fresh_at)

    changeset
    |> validate_after(:license_expires_at, expires_at, :license_effective_at, effective_at)
    |> validate_after(:license_expires_at, expires_at, :evidence_fresh_at, evidence_fresh_at)
  end

  defp validate_opt_in_license(changeset) do
    case get_field(changeset, :license_terms) do
      %{"opt_in" => true} -> changeset
      %{opt_in: true} -> changeset
      _terms -> add_error(changeset, :license_terms, "must record explicit opt-in")
    end
  end

  defp validate_active_license(changeset) do
    now = DateTime.utc_now()
    effective_at = get_field(changeset, :license_effective_at)
    expires_at = get_field(changeset, :license_expires_at)

    changeset
    |> validate_not_after_now(:license_effective_at, effective_at, now)
    |> validate_after_now(:license_expires_at, expires_at, now)
  end

  defp validate_not_after_now(changeset, field, %DateTime{} = at, now) do
    if DateTime.compare(at, now) in [:lt, :eq] do
      changeset
    else
      add_error(changeset, field, "must be active")
    end
  end

  defp validate_not_after_now(changeset, _field, _at, _now), do: changeset

  defp validate_after_now(changeset, field, %DateTime{} = at, now) do
    if DateTime.compare(at, now) == :gt do
      changeset
    else
      add_error(changeset, field, "must be current")
    end
  end

  defp validate_after_now(changeset, _field, _at, _now), do: changeset

  defp validate_after(changeset, field, %DateTime{} = later, earlier_field, %DateTime{} = earlier) do
    if DateTime.compare(later, earlier) == :gt do
      changeset
    else
      add_error(changeset, field, "must be after #{earlier_field}")
    end
  end

  defp validate_after(changeset, _field, _later, _earlier_field, _earlier), do: changeset

  defp put_identity_digests(%Ecto.Changeset{valid?: false} = changeset, _attributes),
    do: changeset

  defp put_identity_digests(changeset, attributes) do
    listing = apply_changes(changeset)

    license_digest =
      Canonical.digest!(%{
        "contract_ref" => listing.license_contract_ref,
        "effective_at" => DateTime.to_iso8601(listing.license_effective_at),
        "expires_at" => DateTime.to_iso8601(listing.license_expires_at),
        "terms" => listing.license_terms
      })

    listing_digest =
      listing
      |> public_identity(license_digest)
      |> Canonical.digest!()

    changeset
    |> verify_supplied_digest(attributes, :license_digest, license_digest)
    |> verify_supplied_digest(attributes, :listing_digest, listing_digest)
    |> put_change(:license_digest, license_digest)
    |> put_change(:listing_digest, listing_digest)
  end

  defp public_identity(listing, license_digest) do
    %{
      "artifact_type" => listing.artifact_type,
      "owner" => %{
        "ref" => listing.owner_ref,
        "description" => listing.owner_description
      },
      "artifact_digest" => listing.artifact_digest,
      "provenance" => Map.put(listing.provenance, "digest", listing.provenance_digest),
      "schema" => listing.schema,
      "size" => %{"bytes" => listing.size_bytes, "records" => listing.record_count},
      "coverage" => listing.coverage,
      "redaction" => listing.redaction,
      "license" => %{
        "contract_ref" => listing.license_contract_ref,
        "digest" => license_digest,
        "terms" => listing.license_terms,
        "effective_at" => DateTime.to_iso8601(listing.license_effective_at),
        "expires_at" => DateTime.to_iso8601(listing.license_expires_at)
      },
      "price" => listing.price,
      "buyer" => %{"name" => listing.buyer_name, "class" => listing.buyer_class},
      "verification_policy" => listing.verification_policy,
      "evidence_fresh_at" => DateTime.to_iso8601(listing.evidence_fresh_at)
    }
  end

  defp verify_supplied_digest(changeset, attributes, field, expected) do
    case attribute(attributes, field) do
      nil -> changeset
      ^expected -> changeset
      _mismatch -> add_error(changeset, field, "does not match the canonical identity")
    end
  end

  defp attribute(attributes, field) do
    Map.get(attributes, field) || Map.get(attributes, Atom.to_string(field))
  end

  defp validate_safe_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_map(value) -> [{field, "must be a map"}]
        contains_private_key?(value) -> [{field, "contains private source metadata"}]
        true -> []
      end
    end)
  end

  defp contains_private_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalize_key(key) in @private_keys or contains_private_key?(value)
    end)
  end

  defp contains_private_key?(values) when is_list(values),
    do: Enum.any?(values, &contains_private_key?/1)

  defp contains_private_key?(_value), do: false

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: ""
end
