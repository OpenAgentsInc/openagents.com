defmodule OpenAgents.Conversations.ProviderStep do
  @moduledoc "Ordered, bounded provider-attempt evidence for a turn receipt."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(started completed failed cancelled interrupted)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "turn_provider_steps" do
    belongs_to :turn_receipt, OpenAgents.Conversations.TurnReceipt
    field :sequence, :integer
    field :provider_id, :string
    field :model_id, :string
    field :status, :string, default: "started"
    field :provider_response_id, :string
    field :usage, :map
    field :error_code, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(step, attributes) do
    step
    |> cast(attributes, [
      :turn_receipt_id,
      :sequence,
      :provider_id,
      :model_id,
      :status,
      :provider_response_id,
      :usage,
      :error_code,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :turn_receipt_id,
      :sequence,
      :provider_id,
      :model_id,
      :status,
      :started_at
    ])
    |> common_validations()
    |> foreign_key_constraint(:turn_receipt_id)
    |> unique_constraint([:turn_receipt_id, :sequence])
  end

  def lifecycle_changeset(step, attributes) do
    step
    |> cast(attributes, [:status, :provider_response_id, :usage, :error_code, :completed_at])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:provider_id, min: 1, max: 128)
    |> validate_length(:model_id, min: 1, max: 256)
    |> validate_length(:provider_response_id, max: 512)
    |> validate_length(:error_code, max: 128)
    |> validate_usage()
  end

  defp validate_usage(changeset) do
    validate_change(changeset, :usage, fn :usage, usage ->
      if byte_size(Jason.encode!(usage)) <= 16_384,
        do: [],
        else: [usage: "is too large"]
    end)
  end
end
