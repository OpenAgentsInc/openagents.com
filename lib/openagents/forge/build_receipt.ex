defmodule OpenAgents.Forge.BuildReceipt do
  @moduledoc """
  Derived record of one build in the forge deploy lane (`forge_builds`).
  Idempotent by `{repo, sha, target_id}`; the artifact tar on disk plus
  the target row carry the operational truth — this is the audit receipt
  (sha, changed modules, bounded compiler/test output, duration).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_builds" do
    field :repo, :string
    field :sha, :string
    field :target_id, :binary_id
    field :modules, {:array, :string}, default: []
    field :warnings, :string
    field :tests, :string
    field :duration_ms, :integer
    field :artifact, :string
    timestamps(updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:repo, :sha, :target_id, :modules, :warnings, :tests, :duration_ms, :artifact])
    |> validate_required([:repo, :sha, :target_id])
    |> unique_constraint([:repo, :sha, :target_id])
  end
end
