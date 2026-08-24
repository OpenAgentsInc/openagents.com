defmodule OpenAgents.Repo.Migrations.CreateEffects do
  @moduledoc """
  The durable effect outbox (issue #202, EFFECT-001).

  Today an intent commits and its effect fires afterwards, from the same
  process, on the same node: `OpenAgents.Work.start_job/1` inserts the job row
  and then asks Horde for a worker. A crash in the gap between those two lines
  leaves a committed `queued` job that nothing is executing, and nothing
  notices until that node boots again. That is the failure class T3 Code's
  teardown names as "best-effort live reactor" loss of committed work
  (`docs/2026-08-24-coder-first-cloud-complements.md` section 3).

  This table closes the gap. The effect row is inserted in the same transaction
  as the intent it belongs to, so either both exist or neither does. After the
  commit any worker on any node may claim it under a lease, dispatch it, and
  record the outcome. The inline launch stays as a fast path; the outbox is
  what makes it safe for the fast path to fail.

  The column set is borrowed from `deployment_runs`
  (`priv/repo/migrations/20260823070000_create_deployment_control_plane.exs`),
  the only other durable execution record here with a lease: the lease owner
  and its expiry, the attempt counter, the last error, and the
  conditional-update claim those support. What is added is the outbox half —
  the source that asked for
  the effect, the payload digest that fingerprints what was asked for, and the
  deterministic idempotency key that makes a redelivery safe.

  Two digests, because they answer different questions. `payload_digest`
  fingerprints the content, so a reused key carrying different content is
  refused instead of silently answered with the first result. `idempotency_key`
  identifies the effect, so the same intent enqueued twice produces one row and
  one delivery.
  """

  use Ecto.Migration

  def change do
    create table(:effects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # What to do, and with what. The kind selects a handler; the payload is
      # the handler's whole input, because a handler that reads anything else
      # is not replayable.
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :payload_digest, :string, null: false

      # Who asked. `source_kind` and `source_id` name the committed intent;
      # `source_sequence` is its transcript position where the source has one.
      # A sequence is a position, never an execution claim (EFFECT-002), so it
      # is recorded beside the status rather than used as one.
      add :source_kind, :string, null: false
      add :source_id, :string, null: false
      add :source_sequence, :bigint

      add :idempotency_key, :string, null: false

      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :maximum_attempts, :integer, null: false, default: 5

      # When the effect may next be claimed. Backoff moves this forward; it is
      # never used to express readiness any other way.
      add :available_at, :utc_datetime_usec, null: false

      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :last_error, :text

      add :claimed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One effect per intent. The unique key is what makes `enqueue/2` safe to
    # call twice — from a retried request, from a replayed reactor, from a
    # caller that does not know whether its last transaction committed.
    create unique_index(:effects, [:idempotency_key])

    # The claim query in one index: pending work, oldest first.
    create index(:effects, [:available_at, :inserted_at],
             where: "status = 'pending'",
             name: :effects_pending_claim_index
           )

    # The reclaim query in one index: leases that have run out.
    create index(:effects, [:lease_expires_at],
             where: "status = 'claimed'",
             name: :effects_expired_lease_index
           )

    # "What happened to the effects this thread/job asked for" without a scan.
    create index(:effects, [:source_kind, :source_id])

    create constraint(:effects, :effects_status_check,
             check: "status IN ('pending', 'claimed', 'done', 'failed')"
           )

    create constraint(:effects, :effects_attempts_nonnegative_check, check: "attempts >= 0")

    create constraint(:effects, :effects_maximum_attempts_positive_check,
             check: "maximum_attempts >= 1"
           )

    create constraint(:effects, :effects_kind_present_check,
             check: "octet_length(kind) BETWEEN 1 AND 80"
           )

    create constraint(:effects, :effects_payload_present_check,
             check: "octet_length(payload::text) >= 2"
           )

    # A lease is a pair or it is nothing: an owner with no expiry never expires,
    # and an expiry with no owner names nobody to reclaim from.
    create constraint(:effects, :effects_lease_pair_check,
             check: """
             (lease_owner IS NULL AND lease_expires_at IS NULL)
             OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
             """
           )

    # A claimed effect holds a lease; a terminal effect holds none and carries
    # the time it reached that state. This is the durable half of the milestone
    # separation: "claimed" and "completed" cannot be the same fact.
    create constraint(:effects, :effects_status_shape_check,
             check: """
             (status = 'pending' AND completed_at IS NULL)
             OR (status = 'claimed' AND lease_owner IS NOT NULL AND claimed_at IS NOT NULL
                 AND completed_at IS NULL)
             OR (status IN ('done', 'failed') AND lease_owner IS NULL
                 AND completed_at IS NOT NULL)
             """
           )
  end
end
