defmodule OpenAgents.Repo.Migrations.ReconcileForgeBuildsReceiptShape do
  @moduledoc """
  Port fix: `forge_builds` was created (223c6f6, "Phase 3 target and receipt
  persistence") with a shape that no module in this repo declares — a bigint
  key plus `source_sha`/`module_changes`/`artifact_path`. The only schema
  bound to that table is `OpenAgents.Forge.BuildReceipt`, which declares the
  upstream receipt shape (`repo`, `sha`, `modules`, `warnings`, `tests`,
  `artifact`, binary id).

  The mismatch is not merely cosmetic: `OpenAgents.Changelog.receipt_index/1`
  selects `forge_builds.repo`, so every query raised `UndefinedColumnError`,
  and `Changelog.build/1`'s `safely/2` rescue swallowed it — dropping the
  push, build **and** deploy receipts for the whole timeline. That is why a
  receipted deploy never appeared as a `:receipt` row and no entry ever
  carried `receipt_ids`.

  Guarded and non-destructive: it acts only when the divergent shape is
  present, and preserves any existing rows by renaming the old table aside
  rather than dropping it.
  """

  use Ecto.Migration

  def up do
    if divergent_shape?() do
      rename(table(:forge_builds), to: table(:forge_builds_phase3_legacy))

      create table(:forge_builds, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :repo, :string, null: false
        add :sha, :string, null: false
        add :target_id, :binary_id, null: false
        add :modules, {:array, :string}, null: false, default: []
        add :warnings, :text
        add :tests, :text
        add :duration_ms, :integer
        add :artifact, :string
        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      create unique_index(:forge_builds, [:repo, :sha, :target_id])
      create index(:forge_builds, [:repo, :inserted_at])
    end
  end

  def down do
    if receipt_shape?() do
      drop table(:forge_builds)
      rename(table(:forge_builds_phase3_legacy), to: table(:forge_builds))
    end
  end

  defp divergent_shape?, do: not has_column?("forge_builds", "repo")

  defp receipt_shape?,
    do: has_column?("forge_builds", "repo") and table?("forge_builds_phase3_legacy")

  defp has_column?(table, column) do
    query?("""
    SELECT 1 FROM information_schema.columns
    WHERE table_name = '#{table}' AND column_name = '#{column}'
    """)
  end

  defp table?(table) do
    query?("SELECT 1 FROM information_schema.tables WHERE table_name = '#{table}'")
  end

  defp query?(sql) do
    case repo().query(sql) do
      {:ok, %{num_rows: n}} -> n > 0
      _ -> false
    end
  end
end
