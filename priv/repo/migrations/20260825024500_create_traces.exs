defmodule OpenAgents.Repo.Migrations.CreateTraces do
  @moduledoc """
  ATIF trace documents uploaded by an account.

  A trace is an owner-attested document with a stable SHA-256 digest. The
  server stores the document as received, deduplicates per owner, and records
  the transparency tier the owner consented to. The vocabulary for the
  `visibility` tier is the shared `dark/pulse/ledger/glass` ladder.
  """

  use Ecto.Migration

  def change do
    create table(:traces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :digest, :string, null: false
      add :visibility, :string, null: false, default: "dark"
      add :document, :map, null: false
      add :byte_size, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:traces, [:user_id, :digest], name: :traces_user_id_digest_index)

    create constraint(:traces, :traces_visibility_check,
             check: "visibility IN ('dark','pulse','ledger','glass')"
           )
  end
end
