defmodule OpenAgents.Agents.AgentBoxGrant do
  @moduledoc "A revocable human grant of Box control to an agent."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_box_control_grants" do
    belongs_to :agent, OpenAgents.Agents.Agent
    belongs_to :user, OpenAgents.Accounts.User
    belongs_to :granted_by, OpenAgents.Accounts.User
    field :scope, :string, default: "box:control"
    field :granted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:scope, :granted_at, :revoked_at])
    |> put_programmatic(attrs, :agent_id)
    |> put_programmatic(attrs, :user_id)
    |> put_programmatic(attrs, :granted_by_id)
    |> validate_required([:agent_id, :user_id, :granted_by_id, :scope, :granted_at])
    |> validate_inclusion(:scope, ["box:control"])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:granted_by_id)
  end

  defp put_programmatic(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
