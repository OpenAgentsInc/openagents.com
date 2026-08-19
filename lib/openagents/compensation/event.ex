defmodule OpenAgents.Compensation.Event do
  @moduledoc "One deduplicated compensation classification for an accepted invocation outcome."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_events" do
    belongs_to :tool_step, OpenAgents.Conversations.ToolStep
    belongs_to :policy_receipt, OpenAgents.Compensation.PolicyReceipt
    belongs_to :outcome_decision, OpenAgents.Compensation.OutcomeDecision
    field :module_id, :string
    field :module_version, :integer
    field :artifact_digest, :string
    field :invocation_key, :string
    field :outcome_receipt_ref, :string
    field :technical_units, :integer
    field :eligible_units, :integer
    field :classification, :string
    field :reason_code, :string
    field :event_digest, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(tool_step_id policy_receipt_id outcome_decision_id module_id module_version artifact_digest invocation_key outcome_receipt_ref technical_units eligible_units classification reason_code event_digest)a
    )
    |> validate_required(
      ~w(tool_step_id policy_receipt_id outcome_decision_id module_id module_version artifact_digest invocation_key outcome_receipt_ref technical_units eligible_units classification reason_code event_digest)a
    )
    |> validate_inclusion(:classification, ~w(eligible ineligible))
    |> validate_number(:technical_units, greater_than_or_equal_to: 0)
    |> validate_number(:eligible_units, greater_than_or_equal_to: 0)
    |> validate_format(:artifact_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:invocation_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:event_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:tool_step_id)
    |> foreign_key_constraint(:policy_receipt_id)
    |> foreign_key_constraint(:outcome_decision_id)
    |> unique_constraint(:tool_step_id)
    |> unique_constraint(:invocation_key)
    |> unique_constraint(:outcome_receipt_ref)
  end
end
