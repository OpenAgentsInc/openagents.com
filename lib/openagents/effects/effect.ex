defmodule OpenAgents.Effects.Effect do
  @moduledoc """
  One durable effect: something a committed intent asked the system to do.

  The row is written inside the transaction that writes the intent, so the two
  cannot disagree. Everything a handler needs is in `payload`, because a
  handler that reads anything else is not replayable.

  `payload_digest` fingerprints the content and `idempotency_key` identifies
  the effect. Those are different questions, and conflating them is the mistake
  `docs/2026-08-24-coder-first-cloud-complements.md` section 3 names: a reused
  id with different content must be refused, not silently answered with the
  first result.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending claimed done failed)

  schema "effects" do
    field :kind, :string
    field :payload, :map
    field :payload_digest, :string

    field :source_kind, :string
    field :source_id, :string
    field :source_sequence, :integer

    field :idempotency_key, :string

    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :maximum_attempts, :integer, default: 5
    field :available_at, :utc_datetime_usec

    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_error, :string
    field :result, :map

    field :claimed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The statuses an effect row may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def enqueue_changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [
      :kind,
      :payload,
      :payload_digest,
      :source_kind,
      :source_id,
      :source_sequence,
      :idempotency_key,
      :maximum_attempts,
      :available_at,
      :result
    ])
    |> validate_required([
      :kind,
      :payload,
      :payload_digest,
      :source_kind,
      :source_id,
      :idempotency_key,
      :available_at
    ])
    |> validate_length(:kind, min: 1, max: 80)
    |> validate_length(:source_kind, min: 1, max: 80)
    |> validate_length(:source_id, min: 1, max: 255)
    |> validate_number(:maximum_attempts, greater_than_or_equal_to: 1)
    |> put_change(:status, "pending")
    |> put_change(:attempts, 0)
    |> unique_constraint(:idempotency_key)
    |> check_constraint(:status, name: :effects_status_check)
    |> check_constraint(:payload, name: :effects_payload_present_check)
    |> check_constraint(:status, name: :effects_status_shape_check)
  end
end
