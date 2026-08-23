defmodule OpenAgents.ContinualLearning.Checkpoint do
  @moduledoc """
  One durable checkpoint of a continual-learning job, written before the round
  that produced it is counted.

  Checkpoints form a digest chain: each one names its parent, so a resume can
  prove it continued the surviving state rather than starting a different run.
  A checkpoint marked `lost` is evidence that the state is gone; a resume that
  finds one refuses instead of silently retraining.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "continual_learning_checkpoints" do
    belongs_to :job, OpenAgents.ContinualLearning.Job
    field :round, :integer
    field :state, :map, default: %{}
    field :state_digest, :string
    field :parent_digest, :string
    field :metrics, :map, default: %{}
    field :usage, :map, default: %{}
    field :energy, :map, default: %{}
    field :lost, :boolean, default: false

    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(checkpoint, attributes, maximum_state_bytes) do
    checkpoint
    |> cast(attributes, [
      :round,
      :state,
      :state_digest,
      :parent_digest,
      :metrics,
      :usage,
      :energy,
      :lost
    ])
    |> validate_required([:round, :state, :state_digest, :metrics])
    |> validate_number(:round, greater_than: 0)
    |> validate_format(:state_digest, @digest_regex)
    |> validate_parent_digest()
    |> validate_state_size(maximum_state_bytes)
    |> unique_constraint([:job_id, :round])
    |> unique_constraint([:job_id, :state_digest])
    |> foreign_key_constraint(:job_id)
  end

  @doc "Marks a checkpoint's state as unrecoverable."
  def loss_changeset(checkpoint) do
    change(checkpoint, %{lost: true, state: %{}})
  end

  defp validate_parent_digest(changeset) do
    case get_field(changeset, :parent_digest) do
      nil -> changeset
      value when is_binary(value) -> validate_format(changeset, :parent_digest, @digest_regex)
      _invalid -> add_error(changeset, :parent_digest, "is invalid")
    end
  end

  defp validate_state_size(changeset, maximum_state_bytes) do
    state = get_field(changeset, :state)

    if is_map(state) and byte_size(Jason.encode!(state)) <= maximum_state_bytes do
      changeset
    else
      add_error(changeset, :state, "exceeds #{maximum_state_bytes} bytes")
    end
  end
end
