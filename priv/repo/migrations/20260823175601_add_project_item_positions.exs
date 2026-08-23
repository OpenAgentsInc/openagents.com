defmodule OpenAgents.Repo.Migrations.AddProjectItemPositions do
  use Ecto.Migration

  # A board reorder needs a stored rank. Without one the only stable order is
  # insertion order by id, which no move can change, so a card can never be
  # placed relative to another card.
  def up do
    alter table(:project_items) do
      add :position, :integer
    end

    # Existing boards already read in id order, so the backfill preserves the
    # order every current reader sees.
    execute("""
    UPDATE project_items AS item
    SET position = ranked.rank
    FROM (
      SELECT id, row_number() OVER (PARTITION BY project_id ORDER BY id) AS rank
      FROM project_items
    ) AS ranked
    WHERE item.id = ranked.id
    """)

    execute("ALTER TABLE project_items ALTER COLUMN position SET DEFAULT 0")
    execute("ALTER TABLE project_items ALTER COLUMN position SET NOT NULL")

    create index(:project_items, [:project_id, :position])
  end

  def down do
    drop index(:project_items, [:project_id, :position])

    alter table(:project_items) do
      remove :position
    end
  end
end
