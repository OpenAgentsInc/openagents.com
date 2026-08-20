defmodule OpenAgents.ProgramLifecycle.ArtifactRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "program_lifecycle_artifacts" do
    field :artifact_id, :string
    field :signature_id, :string
    field :digest, :string
    field :stage, :string
    field :predecessor_artifact_id, :string
    field :document, :map
    timestamps()
  end

  def changeset(record, attributes) do
    record
    |> cast(attributes, [
      :artifact_id,
      :signature_id,
      :digest,
      :stage,
      :predecessor_artifact_id,
      :document
    ])
    |> validate_required([:artifact_id, :signature_id, :digest, :stage, :document])
    |> validate_inclusion(:stage, ~w(candidate approved active))
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:artifact_id)
    |> unique_constraint(:digest)
  end
end
