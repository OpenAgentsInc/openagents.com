defmodule OpenAgents.ProgramLifecycle.Activation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:signature_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "active_program_artifacts" do
    field :artifact_id, :string
    field :artifact_digest, :string
    field :generation, :integer
    field :activation_event_id, :binary_id
    timestamps()
  end

  def changeset(activation, attributes) do
    activation
    |> cast(attributes, [:artifact_id, :artifact_digest, :generation, :activation_event_id])
    |> validate_required([
      :signature_id,
      :artifact_id,
      :artifact_digest,
      :generation,
      :activation_event_id
    ])
    |> validate_number(:generation, greater_than: 0)
    |> validate_format(:artifact_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
