defmodule OpenAgents.Repo.Migrations.CreateAgentBoxControlGrants do
  use Ecto.Migration

  def change do
    create table(:agent_box_control_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :granted_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :scope, :string, null: false, default: "box:control"
      add :granted_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_box_control_grants, [:agent_id, :scope],
             where: "revoked_at IS NULL"
           )

    create index(:agent_box_control_grants, [:user_id])

    create constraint(:agent_box_control_grants, :agent_box_control_grants_scope_check,
             check: "scope = 'box:control'"
           )
  end
end
