defmodule OpenAgents.Repo.Migrations.CreateIssueEvidence do
  use Ecto.Migration

  def change do
    create table(:issue_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false

      # The exact revision the receipt evaluated. Never abbreviated: a receipt
      # that qualified `9606cbc` did not qualify every commit that starts with
      # those seven characters.
      add :commit_sha, :string, null: false, size: 64

      # Which receipt family this row binds. One of the named families, so a
      # reader never has to guess whether a receipt is a push or a deploy.
      add :family, :string, null: false, size: 32

      # The receipt's own primary key, in whichever table its family owns.
      # Together with the family it is the identity of the evidence.
      add :receipt_id, :binary_id, null: false

      # Which store the receipt lives in: the forge's own release lane, or the
      # tenant deployment control plane. The two planes never mix.
      add :plane, :string, null: false, size: 16

      # The environment the receipt names, when its family has one. `nil` for a
      # push and a build, which reach no environment.
      add :environment, :string, size: 120

      # The receipt's own terminal word, copied so a timeline can read the
      # outcome without joining four tables. Never re-derived.
      add :result, :string, size: 64

      # The principal the evidence is attributed to, in the same
      # `type:id` shape the push receipts and closing references already use.
      add :actor, :string, null: false, size: 200

      # How this row was resolved to its issue: the commit trailer #130
      # extracted, or the attempt that reported the revision.
      add :source, :string, null: false, size: 32

      add :assignment_id, references(:forge_assignments, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The idempotency gate, and the reason replay cannot duplicate an edge. A
    # receipt id is unique within its family, so the same receipt reaches the
    # same issue at the same commit exactly once however many times the WAL
    # replays or `reconcile_receipts/1` runs. The actor is a property of the
    # row rather than part of its identity: putting it in the key would let a
    # replay that resolved the principal differently write the edge twice.
    create unique_index(:issue_evidence, [:issue_id, :commit_sha, :family, :receipt_id])

    # The receipt side of the join: given a commit that just produced a
    # receipt, which issues already claim it.
    create index(:issue_evidence, [:repository_id, :commit_sha])

    # The issue side: one issue's evidence chain, oldest first.
    create index(:issue_evidence, [:issue_id, :inserted_at])

    create constraint(:issue_evidence, :issue_evidence_family,
             check: "family IN ('push','build','deployment','qualification')"
           )

    create constraint(:issue_evidence, :issue_evidence_plane,
             check: "plane IN ('forge','tenant')"
           )

    create constraint(:issue_evidence, :issue_evidence_source,
             check: "source IN ('closing_reference','assignment')"
           )

    create constraint(:issue_evidence, :issue_evidence_commit_sha,
             check: "commit_sha ~ '^[0-9a-f]{7,64}$'"
           )

    # A receipt arriving for a commit asks which issues claim that commit, and
    # an attempt reporting a commit asks which receipts already exist for it.
    # Both directions scan by `{repo, sha}`, which nothing indexed before.
    create index(:forge_builds, [:repo, :sha])
    create index(:forge_deploys, [:repo, :sha])
  end
end
