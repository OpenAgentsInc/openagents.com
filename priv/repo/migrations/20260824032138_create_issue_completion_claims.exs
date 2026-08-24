defmodule OpenAgents.Repo.Migrations.CreateIssueCompletionClaims do
  use Ecto.Migration

  def change do
    # The opt-in. Both flags default to false, so a repository that has said
    # nothing is a repository where nothing closes itself and no claim is even
    # graded. Silence is never consent here: the absent row and the row with
    # both flags false must mean the same thing.
    create table(:repository_closure_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      # Whether agent-authored claims are graded at all. False makes every
      # claim `not_applicable`, which is the accepted-outcome contract's own
      # word for work outside the gate.
      add :agents_enabled, :boolean, null: false, default: false

      # Whether an accepted claim may close the issue. False records the
      # verdict and leaves the issue open for a person to act on.
      add :verified_closing_enabled, :boolean, null: false, default: false

      add :updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_closure_policies, [:repository_id])

    create table(:issue_completion_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false

      # The attempt. Not nullable: three of the five attempt fields the
      # contract binds — the authority, the budget, and the revision — are
      # only reachable through an assignment, so a claim without one could
      # never be graded as anything but incomplete.
      add :assignment_id,
          references(:forge_assignments, type: :binary_id, on_delete: :delete_all), null: false

      # The exact revision the claim is about, copied from the attempt's own
      # terminal report rather than from the caller.
      add :revision, :string, null: false, size: 64

      # The graded verdict: the accepted-outcome contract's own vocabulary.
      add :state, :string, null: false, size: 32

      # The typed reasons a non-accepted verdict carries, rendered as strings.
      add :reasons, {:array, :string}, null: false, default: []

      # Which evidence satisfied which acceptance criterion, and nothing else.
      add :criteria, {:array, :map}, null: false, default: []

      # The verifier's identity and the falsifier it recorded, so a reader can
      # ask what observation would have made this red.
      add :verifier, :string, size: 200
      add :falsifier, :string, size: 500

      # The closure half. `closed_by_actor` is a system principal and never a
      # user: a person's close is a `issue_closing_references` row with a
      # `closed_by_user_id`, and the two records cannot be confused.
      add :closed, :boolean, null: false, default: false
      add :closed_at, :utc_datetime_usec
      add :closed_by_actor, :string, size: 200

      # A later receipt that disagreed with the evidence this claim rested on.
      # It never reopens the issue; it records that the ground moved.
      add :contradicted_at, :utc_datetime_usec

      add :contradicted_by_evidence_id,
          references(:issue_evidence, type: :binary_id, on_delete: :nilify_all)

      add :contradiction_reason, :string, size: 200

      timestamps(type: :utc_datetime_usec)
    end

    # `{issue, attempt, revision}` is the key #150 names. One attempt reporting
    # one revision produces one graded claim however many times it is
    # submitted, so a resubmission updates a verdict rather than accumulating
    # verdicts nobody can order.
    create unique_index(:issue_completion_claims, [:issue_id, :assignment_id, :revision])

    # The contradiction lookup: a failing receipt lands for a commit and asks
    # which claims rested on that exact revision of that exact issue.
    create index(:issue_completion_claims, [:issue_id, :revision])

    create constraint(:issue_completion_claims, :issue_completion_claims_state,
             check: "state IN ('accepted','incomplete','unauthorized','failed','not_applicable')"
           )

    create constraint(:issue_completion_claims, :issue_completion_claims_revision,
             check: "revision ~ '^[0-9a-f]{7,64}$'"
           )

    # Only an accepted claim may carry a close. A row that says it closed an
    # issue on an `incomplete` verdict is the exact failure this issue exists
    # to prevent, so PostgreSQL refuses it rather than trusting the caller.
    create constraint(:issue_completion_claims, :issue_completion_claims_close_requires_accepted,
             check: "closed = false OR (state = 'accepted' AND closed_at IS NOT NULL)"
           )
  end
end
