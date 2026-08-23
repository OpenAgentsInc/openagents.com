defmodule OpenAgents.ArtifactCatalog.Receipt do
  @moduledoc "Append-only evidence for a verified artifact transaction."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @private_keys ~w(
    email message_id private_source_ref raw_source secret source_path source_ref source_uri token
    user_id
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "verified_artifact_receipts" do
    belongs_to :listing, OpenAgents.ArtifactCatalog.Listing
    field :action, :string
    field :status, :string
    field :receipt_ref, :string
    field :predecessor_ref, :string
    field :external_ref, :string
    field :buyer_ref, :string
    field :buyer_class, :string
    field :artifact_digest, :string
    field :provenance_digest, :string
    field :license_digest, :string
    field :listing_digest, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :action,
      :status,
      :receipt_ref,
      :predecessor_ref,
      :external_ref,
      :buyer_ref,
      :buyer_class,
      :artifact_digest,
      :provenance_digest,
      :license_digest,
      :listing_digest,
      :metadata
    ])
    |> validate_required([
      :listing_id,
      :action,
      :status,
      :receipt_ref,
      :buyer_ref,
      :buyer_class,
      :artifact_digest,
      :provenance_digest,
      :license_digest,
      :listing_digest,
      :metadata
    ])
    |> validate_inclusion(
      :action,
      ~w(publication offer acceptance delivery verification settlement removal)
    )
    |> validate_inclusion(:status, ~w(recorded admitted verified settled removed))
    |> validate_format(:artifact_digest, @digest_regex)
    |> validate_format(:provenance_digest, @digest_regex)
    |> validate_format(:license_digest, @digest_regex)
    |> validate_format(:listing_digest, @digest_regex)
    |> validate_length(:receipt_ref, min: 1, max: 256)
    |> validate_length(:predecessor_ref, min: 1, max: 256)
    |> validate_length(:external_ref, min: 1, max: 256)
    |> validate_length(:buyer_ref, min: 1, max: 256)
    |> validate_length(:buyer_class, min: 1, max: 128)
    |> validate_safe_metadata()
    |> foreign_key_constraint(:listing_id)
    |> unique_constraint(:receipt_ref)
  end

  def projection(%__MODULE__{} = receipt) do
    %{
      "action" => receipt.action,
      "status" => receipt.status,
      "receipt_ref" => receipt.receipt_ref,
      "predecessor_ref" => receipt.predecessor_ref,
      "external_ref" => receipt.external_ref,
      "buyer_ref" => receipt.buyer_ref,
      "buyer_class" => receipt.buyer_class,
      "artifact_digest" => receipt.artifact_digest,
      "provenance_digest" => receipt.provenance_digest,
      "license_digest" => receipt.license_digest,
      "listing_digest" => receipt.listing_digest,
      "metadata" => receipt.metadata,
      "recorded_at" => receipt.inserted_at
    }
  end

  defp validate_safe_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      cond do
        not is_map(value) -> [metadata: "must be a map"]
        contains_private_key?(value) -> [metadata: "contains private source metadata"]
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
