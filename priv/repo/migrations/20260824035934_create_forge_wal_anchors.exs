defmodule OpenAgents.Repo.Migrations.CreateForgeWalAnchors do
  use Ecto.Migration

  # The published WAL anchor (`EXIT-005`, ADR 0008). One row per published
  # anchor document, holding the exact bytes that were served rather than the
  # fields they were built from: the digest a reader computes is a digest of
  # the bytes they fetched, and the next anchor names that digest.
  #
  # `anchor_seq` is unique because a published sequence with two different
  # documents behind it would break the chain a reader walks back. Two nodes
  # publishing in the same interval race here, and the loser retries next tick.
  #
  # This table is a publication record, never authority. Nothing reads it to
  # decide what the forge serves, and `OpenAgents.Forge.Verification` reaches
  # no database at all.
  def change do
    create table(:forge_wal_anchors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :anchor_seq, :bigint, null: false
      add :digest, :string, null: false
      add :previous_digest, :string
      add :body, :text, null: false
      add :published_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:forge_wal_anchors, [:anchor_seq])
  end
end
