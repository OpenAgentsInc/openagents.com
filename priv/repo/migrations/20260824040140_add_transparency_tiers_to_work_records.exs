defmodule OpenAgents.Repo.Migrations.AddTransparencyTiersToWorkRecords do
  use Ecto.Migration

  # `#70` gave `artifact_links` a check constraint on the tier and none on the
  # artifact type or the ref kind, so the vocabulary `ArtifactLink` validated
  # in Elixir was not a vocabulary the database held. Adding the work members
  # is the moment to make both real: a type nobody declared, and a ref kind
  # nobody declared, are now refused by PostgreSQL rather than by a changeset
  # a direct writer can skip.
  def change do
    create constraint(:artifact_links, :artifact_links_artifact_type_check,
             check:
               "artifact_type IN ('changelog','release','issue','build','attempt','work_job','deployment','trace')"
           )

    create constraint(:artifact_links, :artifact_links_artifact_ref_check,
             check: "artifact_ref IN ('sha','tag','digest','path','id')"
           )

    # The tier is the ceiling the record consents to, and the viewer's own
    # relationship to the repository clamps it down from there. `ledger` is the
    # default because it is what a repository member already saw: the column
    # narrows anonymous traffic on a public repository, and narrows nobody who
    # was already inside.
    alter table(:forge_assignments) do
      add :transparency_tier, :string, null: false, default: "ledger"
      add :artifact_link_id, references(:artifact_links, type: :binary_id, on_delete: :nothing)
    end

    alter table(:issue_evidence) do
      add :transparency_tier, :string, null: false, default: "ledger"
      add :artifact_link_id, references(:artifact_links, type: :binary_id, on_delete: :nothing)
    end

    create constraint(:forge_assignments, :forge_assignments_transparency_tier_check,
             check: "transparency_tier IN ('dark','pulse','ledger','glass')"
           )

    create constraint(:issue_evidence, :issue_evidence_transparency_tier_check,
             check: "transparency_tier IN ('dark','pulse','ledger','glass')"
           )

    create index(:forge_assignments, [:artifact_link_id])
    create index(:issue_evidence, [:artifact_link_id])
  end
end
