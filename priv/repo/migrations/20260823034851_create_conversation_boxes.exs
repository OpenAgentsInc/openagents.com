defmodule OpenAgents.Repo.Migrations.CreateConversationBoxes do
  use Ecto.Migration

  def change do
    create table(:conversation_boxes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :box_id, :string, null: false
      add :state, :string, null: false, default: "provisioning"
      add :setup_status, :string, null: false, default: "pending"
      add :stopped_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_boxes, [:box_id])
    create index(:conversation_boxes, [:conversation_id])
  end
end
