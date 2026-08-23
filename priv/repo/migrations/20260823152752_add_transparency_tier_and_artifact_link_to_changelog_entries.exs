defmodule OpenAgents.Repo.Migrations.AddTransparencyTierAndArtifactLinkToChangelogEntries do
  use Ecto.Migration

  def change do
    alter table(:changelog_entries) do
      add :transparency_tier, :string
      add :artifact_link_id, references(:artifact_links, type: :binary_id, on_delete: :nothing)
    end
  end
end
