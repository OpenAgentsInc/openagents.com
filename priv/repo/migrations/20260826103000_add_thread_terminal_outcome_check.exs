defmodule OpenAgents.Repo.Migrations.AddThreadTerminalOutcomeCheck do
  use Ecto.Migration

  @moduledoc """
  A thread's terminal status and its error code have to agree.

  `succeeded` means no error code; every other terminal status names one. The
  rule exists because the terminal row is the durable record of what a session
  did, and the two ways it can lie are symmetric: a session that answered and
  exited 0 recorded as `cancelled` (issue #106), and a session that failed, was
  interrupted, or ran out of steps recorded as `succeeded`. Giving
  `OpenAgents.Threads.finish/2` an HTTP route makes the second one reachable by
  any client, so the pair is refused here as well as in the changeset.

  The constraint is created `NOT VALID`: it is enforced on every insert and
  update from this point on, and the historical scan is skipped so the
  migration does not hold a lock over the whole table while the previous
  release is still serving. Every writer that has ever ended a thread —
  `cancel/2`, the authority reaper, and `finish/2`'s default — already writes a
  pair this admits, so there is nothing for the scan to find; skipping it is a
  deployment courtesy rather than a concession.
  """

  def up do
    execute("""
    ALTER TABLE threads
    ADD CONSTRAINT threads_terminal_outcome_check
    CHECK (
      status = 'open'
      OR (status = 'succeeded' AND (error_code IS NULL OR btrim(error_code) = ''))
      OR (status <> 'succeeded' AND error_code IS NOT NULL AND btrim(error_code) <> '')
    )
    NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE threads DROP CONSTRAINT threads_terminal_outcome_check")
  end
end
