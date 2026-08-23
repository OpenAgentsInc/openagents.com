defmodule OpenAgents.Repo.Migrations.AddWorkspacePublicationToPullRequests do
  use Ecto.Migration

  def change do
    alter table(:pull_requests) do
      add :draft, :boolean, null: false, default: true

      add :repository_publication_id,
          references(:repository_publications, type: :binary_id, on_delete: :restrict)

      add :opened_by_user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :conversation_id, :binary_id
    end

    create unique_index(:pull_requests, [:repository_publication_id],
             where: "repository_publication_id IS NOT NULL"
           )
  end
end
