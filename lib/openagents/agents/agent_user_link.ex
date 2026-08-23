defmodule OpenAgents.Agents.AgentUserLink do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_user_links" do
    field :status, :string, default: "pending"
    field :proof_method, :string
    field :proof_evidence, :map
    field :linked_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :agent, OpenAgents.Agents.Agent
    belongs_to :user, OpenAgents.Accounts.User

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :agent_id,
      :user_id,
      :status,
      :proof_method,
      :proof_evidence,
      :linked_at,
      :rejected_at
    ])
    |> validate_required([:agent_id, :user_id])
    |> validate_inclusion(:status, ["pending", "linked", "rejected", "unlinked"])
    |> unique_constraint([:agent_id, :user_id])
    |> check_constraint(:status, name: :agent_user_links_status_check)
  end
end
