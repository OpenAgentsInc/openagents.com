defmodule OpenAgents.Blueprint.Revision do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "sarah_blueprint_revisions" do
    field :revision, :string
    field :sequence, :integer
    field :parent_revision, :string
    field :digest, :string
    field :status, :string, default: "admitted"
    field :compatibility_min, :integer
    field :compatibility_max, :integer
    field :author, :string
    field :reason, :string
    field :receipt, :map, default: %{}
    has_many :facts, OpenAgents.Blueprint.Fact
    timestamps()
  end

  def changeset(revision, attributes) do
    revision
    |> cast(attributes, [
      :revision,
      :sequence,
      :parent_revision,
      :digest,
      :status,
      :compatibility_min,
      :compatibility_max,
      :author,
      :reason,
      :receipt
    ])
    |> validate_required([
      :revision,
      :sequence,
      :digest,
      :status,
      :compatibility_min,
      :compatibility_max,
      :author,
      :reason,
      :receipt
    ])
    |> validate_inclusion(:status, ["admitted"])
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:compatibility_min, greater_than: 0)
    |> validate_length(:revision, min: 1, max: 100)
    |> validate_length(:author, min: 1, max: 200)
    |> validate_length(:reason, min: 1, max: 2_000)
    |> unique_constraint(:revision)
    |> unique_constraint(:sequence)
  end
end
