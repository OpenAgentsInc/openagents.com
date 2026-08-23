defmodule OpenAgents.Deployments.Approval do
  @moduledoc """
  One approver's decision on one run.

  The decision records the request digest it was made against, so an approval
  can never be carried onto different bytes: if the input changes, the run
  changes, and the old approval no longer applies to anything.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @decisions ~w(approved rejected)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_approvals" do
    field :decision, :string
    field :rule, :string
    field :request_digest, :string
    field :comment, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :deployment_run, OpenAgents.Deployments.Run
    belongs_to :approver_user, OpenAgents.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:decision, :comment])
    |> validate_required([:decision, :rule, :request_digest, :decided_at])
    |> validate_inclusion(:decision, @decisions)
    |> validate_length(:comment, max: 500)
    |> unique_constraint(:approver_user_id,
      name: :deployment_approvals_deployment_run_id_approver_user_id_index
    )
  end

  @doc "The decisions an approver can record."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions
end
