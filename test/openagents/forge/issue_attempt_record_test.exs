defmodule OpenAgents.Forge.IssueAttemptRecordTest do
  @moduledoc """
  One record binds an issue to an execution attempt.

  `#10` forbids a second work record, and `#152` settled the one that had
  arrived by accident: `scv_runs.issue_id` was a fourth issue-to-work edge that
  no caller ever set. `forge_assignments` is the attempt, and these tests hold
  that line at the database rather than in prose.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Repo
  alias OpenAgents.SCV.Execution

  # Every durable execution record a reader could mistake for the attempt.
  @execution_tables ~w(forge_assignments work_jobs box_runs scv_runs)

  test "exactly one durable execution table carries an issue reference" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND column_name = 'issue_id'
          AND table_name = ANY($1)
        ORDER BY table_name
        """,
        [@execution_tables]
      )

    assert List.flatten(rows) == ["forge_assignments"]
  end

  test "an SCV run neither stores nor casts an issue" do
    refute :issue_id in Execution.__schema__(:fields)
    refute :issue in Execution.__schema__(:associations)

    changeset = Execution.claim_changeset(%Execution{}, %{issue_id: 1})
    refute Map.has_key?(changeset.changes, :issue_id)
  end
end
