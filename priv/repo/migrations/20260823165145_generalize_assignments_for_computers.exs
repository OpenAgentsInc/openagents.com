defmodule OpenAgents.Repo.Migrations.GeneralizeAssignmentsForComputers do
  use Ecto.Migration

  def up do
    alter table(:machines) do
      add :scoped_forge_credentials_enabled, :boolean, null: false, default: false
    end

    alter table(:forge_assignments) do
      modify :conversation_box_id, :binary_id, null: true
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :restrict)
      add :target_kind, :string
      add :machine_id, references(:machines, type: :binary_id, on_delete: :restrict)
    end

    execute("""
    UPDATE forge_assignments
    SET target_kind = 'box',
        conversation_id = conversation_boxes.conversation_id
    FROM conversation_boxes
    WHERE forge_assignments.conversation_box_id = conversation_boxes.id
    """)

    alter table(:forge_assignments) do
      modify :target_kind, :string, null: false, default: "box"
    end

    create constraint(:forge_assignments, :forge_assignments_target_kind_check,
             check: "target_kind IN ('box', 'computer')"
           )

    create index(:forge_assignments, [:machine_id])

    create unique_index(:forge_assignments, [:machine_id],
             name: :forge_assignments_one_active_machine_index,
             where: "state IN ('admitted', 'running')"
           )
  end

  def down do
    result =
      repo().query!("""
      SELECT COUNT(*)
      FROM forge_assignments
      WHERE target_kind = 'computer'
      """)

    [[computer_assignments]] = result.rows

    if computer_assignments > 0 do
      raise "cannot roll back computer assignments while computer rows remain"
    end

    drop_if_exists(
      unique_index(:forge_assignments, [:machine_id],
        name: :forge_assignments_one_active_machine_index
      )
    )

    drop_if_exists(index(:forge_assignments, [:machine_id]))
    drop constraint(:forge_assignments, :forge_assignments_target_kind_check)

    alter table(:forge_assignments) do
      remove :conversation_id
      remove :machine_id
      remove :target_kind
      modify :conversation_box_id, :binary_id, null: false
    end

    alter table(:machines) do
      remove :scoped_forge_credentials_enabled
    end
  end
end
