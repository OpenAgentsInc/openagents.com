defmodule OpenAgents.Modules.RouteReceipt do
  @moduledoc "Append-only bounded provenance for one module routing decision."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @statuses ~w(selected unavailable refused)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "module_route_receipts" do
    belongs_to :turn_receipt, OpenAgents.Conversations.TurnReceipt
    field :provider_call_id, :string
    field :status, :string
    field :reason, :string
    field :intent_digest, :string
    field :registry_digest, :string
    field :policy_id, :string
    field :policy_digest, :string
    field :required_capability, :string
    field :required_side_effect, :string
    field :surface, :string
    field :selected, :map
    field :proposed, :map
    field :rejected, {:array, :map}, default: []
    field :program_artifact, :map
    field :fallback, :boolean, default: false
    field :degraded, :boolean, default: false
    timestamps()
  end

  @type t :: %__MODULE__{}

  def create_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :turn_receipt_id,
      :provider_call_id,
      :status,
      :reason,
      :intent_digest,
      :registry_digest,
      :policy_id,
      :policy_digest,
      :required_capability,
      :required_side_effect,
      :surface,
      :selected,
      :proposed,
      :rejected,
      :program_artifact,
      :fallback,
      :degraded
    ])
    |> validate_required([
      :turn_receipt_id,
      :provider_call_id,
      :status,
      :reason,
      :intent_digest,
      :registry_digest,
      :policy_id,
      :policy_digest,
      :required_capability,
      :required_side_effect,
      :surface,
      :fallback,
      :degraded
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:required_side_effect, ~w(read_only reversible_write external_effect))
    |> validate_inclusion(:surface, OpenAgents.Modules.SurfacePolicy.surfaces())
    |> validate_length(:provider_call_id, min: 1, max: 256)
    |> validate_length(:reason, min: 1, max: 256)
    |> validate_length(:policy_id, min: 1, max: 128)
    |> validate_length(:required_capability, min: 1, max: 128)
    |> validate_format(:intent_digest, @digest_regex)
    |> validate_format(:registry_digest, @digest_regex)
    |> validate_format(:policy_digest, @digest_regex)
    |> validate_candidate_payloads()
    |> foreign_key_constraint(:turn_receipt_id)
    |> unique_constraint([:turn_receipt_id, :provider_call_id])
  end

  defp validate_candidate_payloads(changeset) do
    validate_change(changeset, :rejected, fn :rejected, rejected ->
      if is_list(rejected) and length(rejected) <= 64 and bounded_json?(rejected, 32_768),
        do: [],
        else: [rejected: "must be a bounded candidate projection"]
    end)
    |> validate_bounded_map(:selected, 2_048)
    |> validate_bounded_map(:proposed, 2_048)
    |> validate_bounded_map(:program_artifact, 2_048)
  end

  defp validate_bounded_map(changeset, field, maximum) do
    validate_change(changeset, field, fn ^field, value ->
      if is_nil(value) or (is_map(value) and bounded_json?(value, maximum)),
        do: [],
        else: [{field, "must be a bounded projection"}]
    end)
  end

  defp bounded_json?(value, maximum) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= maximum
      {:error, _reason} -> false
    end
  end
end
