defmodule OpenAgents.Repo.Migrations.AddProjectFieldNameAndTypeConstraints do
  use Ecto.Migration

  # A field name is the key an item's stored values are written under, so two
  # fields sharing a name on one project would make an item value ambiguous.
  # The comparison is case-insensitive for the same reason a repository name is:
  # "Status" and "status" name the same column to everyone reading the board.
  def up do
    create unique_index(:project_fields, ["project_id", "lower(name)"],
             name: :project_fields_project_id_name_index
           )

    create constraint(:project_fields, :project_fields_data_type_check,
             check: "data_type in ('text', 'number', 'date', 'single_select', 'promise_state')"
           )
  end

  def down do
    drop constraint(:project_fields, :project_fields_data_type_check)
    drop index(:project_fields, [:project_id], name: :project_fields_project_id_name_index)
  end
end
