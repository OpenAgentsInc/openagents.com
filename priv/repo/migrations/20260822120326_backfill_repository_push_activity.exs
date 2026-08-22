defmodule OpenAgents.Repo.Migrations.BackfillRepositoryPushActivity do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE repositories AS repository
    SET updated_at = latest_push.accepted_at
    FROM (
      SELECT repo, MAX(inserted_at) AS accepted_at
      FROM forge_pushes
      GROUP BY repo
    ) AS latest_push
    WHERE repository.storage_key = latest_push.repo
      AND repository.updated_at < latest_push.accepted_at
    """)
  end

  def down, do: :ok
end
