defmodule OpenAgents.ShadowPrograms.Run do
  @moduledoc "Immutable terminal comparison receipt for one shadow decision."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @type t :: %__MODULE__{}

  schema "shadow_program_runs" do
    belongs_to :turn_receipt, OpenAgents.Conversations.TurnReceipt
    field :signature_id, :string
    field :signature_version, :integer
    field :artifact_id, :string
    field :artifact_digest, :string
    field :input_digest, :string
    field :baseline_output, :map
    field :candidate_output, :map
    field :candidate_output_digest, :string
    field :status, :string
    field :comparison, :map
    field :provider_id, :string
    field :provider_response_id, :string
    field :usage, :map
    field :latency_ms, :integer
    field :failure_code, :string
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(run, attributes) do
    run
    |> cast(attributes, [
      :signature_id,
      :signature_version,
      :artifact_id,
      :artifact_digest,
      :input_digest,
      :baseline_output,
      :candidate_output,
      :candidate_output_digest,
      :status,
      :comparison,
      :provider_id,
      :provider_response_id,
      :usage,
      :latency_ms,
      :failure_code,
      :completed_at
    ])
    |> validate_required([
      :signature_id,
      :signature_version,
      :input_digest,
      :baseline_output,
      :status,
      :comparison,
      :provider_id,
      :latency_ms,
      :completed_at
    ])
    |> validate_inclusion(:status, ~w(completed degraded malformed failed timed_out))
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_format(:input_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:turn_receipt_id)
  end
end
