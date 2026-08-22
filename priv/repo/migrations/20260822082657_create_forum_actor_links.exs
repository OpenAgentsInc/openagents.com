defmodule OpenAgents.Repo.Migrations.CreateForumActorLinks do
  use Ecto.Migration

  def change do
    create table(:forum_actor_links, primary_key: false) do
      add :id, :uuid, primary_key: true

      # The legacy identity from the Effect forum, such as
      # "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20".
      add :actor_ref, :string, null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :status, :string, null: false, default: "pending"
      add :proof_method, :string
      add :proof_evidence, :map
      add :linked_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forum_actor_links, [:actor_ref])
    create unique_index(:forum_actor_links, [:user_id, :actor_ref])

    create constraint(:forum_actor_links, :forum_actor_links_status_check,
             check: "status IN ('pending', 'linked', 'rejected')"
           )
  end
end
