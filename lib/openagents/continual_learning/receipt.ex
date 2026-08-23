defmodule OpenAgents.ContinualLearning.Receipt do
  @moduledoc """
  One append-only receipt of a continual-learning job.

  The sequence is dense per job, so a reader can tell a missing receipt from a
  receipt that was never written, and every payload carries its own canonical
  digest.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(admission usage energy training evaluation artifact settlement resume refusal)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "continual_learning_receipts" do
    belongs_to :job, OpenAgents.ContinualLearning.Job
    field :kind, :string
    field :sequence, :integer
    field :receipt_ref, :string
    field :payload, :map, default: %{}
    field :digest, :string

    timestamps()
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:kind, :sequence, :receipt_ref, :payload, :digest])
    |> validate_required([:kind, :sequence, :receipt_ref, :payload, :digest])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:receipt_ref, min: 1, max: 256)
    |> validate_format(:digest, @digest_regex)
    |> unique_constraint([:job_id, :sequence])
    |> unique_constraint(:receipt_ref)
    |> foreign_key_constraint(:job_id)
  end
end
