defmodule OpenAgents.Compensation.OutcomeDecision do
  @moduledoc "Independent acceptance or rejection of one immutable module outcome."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_outcome_decisions" do
    belongs_to :tool_step, OpenAgents.Conversations.ToolStep
    field :invocation_key, :string
    field :outcome_receipt_ref, :string
    field :outcome_digest, :string
    field :decision, :string
    field :reason_code, :string
    field :actor_id, :string
    field :auth_method, :string
    field :decision_receipt_ref, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(tool_step_id invocation_key outcome_receipt_ref outcome_digest decision reason_code actor_id auth_method decision_receipt_ref)a
    )
    |> validate_required(
      ~w(tool_step_id invocation_key outcome_receipt_ref outcome_digest decision reason_code actor_id auth_method decision_receipt_ref)a
    )
    |> validate_inclusion(:decision, ~w(accepted rejected))
    |> validate_format(:invocation_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:outcome_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:reason_code, min: 1, max: 64)
    |> foreign_key_constraint(:tool_step_id)
    |> unique_constraint(:tool_step_id)
    |> unique_constraint(:outcome_receipt_ref)
    |> unique_constraint(:decision_receipt_ref)
  end
end
