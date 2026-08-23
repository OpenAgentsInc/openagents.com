defmodule OpenAgents.Repo.Migrations.CreateThreadsAndThreadEvents do
  @moduledoc """
  A thread is the unit of agent work (`docs/taxonomy.md`): one objective, its
  turns, its transcript, and its budget. It is account-scoped, plural, and
  disposable, and it requires no conversation — that is the whole point, since
  the account has exactly one conversation (DATA-002) and a thread is not one.

  The column set is borrowed from `scv_runs`
  (`priv/repo/migrations/20260821082652_create_scv_runs.exs`), which is the only
  durable execution record in this repository with no `conversation_id`: the
  bounded objective, the admitted execution shape, the status ladder, the
  monotonic generation, the terminal report plus digest, the event counter and
  usage map, and an append-only event log pinned to a schema string with a
  payload ceiling. What is not borrowed is the coupling to a Codex driver
  account: a thread's owner is the account's visitor root, so the DATA-004
  cascade reaches it without a new rule, and its executor is a property rather
  than its identity.
  """

  use Ecto.Migration

  def change do
    create table(:threads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :objective, :text, null: false
      add :status, :string, null: false, default: "open"
      add :model, :string, null: false
      add :reasoning_effort, :string, null: false
      add :permission_profile, :string, null: false

      # The authority fence. Every grant minted for this thread bumps the
      # generation, so an older generation's authority is provably stale.
      add :generation, :bigint, null: false, default: 0

      add :report, :text
      add :report_digest, :string
      add :error_code, :string
      add :event_count, :integer, null: false, default: 0
      add :usage, :map, null: false, default: %{}

      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:owner_visitor_id, :inserted_at])
    create index(:threads, [:status, :started_at])

    create constraint(:threads, :threads_status_check,
             check: "status IN ('open', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:threads, :threads_objective_bound_check,
             check: "octet_length(objective) BETWEEN 1 AND 32768"
           )

    create constraint(:threads, :threads_report_bound_check,
             check: "report IS NULL OR octet_length(report) BETWEEN 1 AND 32768"
           )

    create constraint(:threads, :threads_permission_profile_check,
             check: "permission_profile IN ('read_only', 'workspace_write')"
           )

    create constraint(:threads, :threads_reasoning_effort_check,
             check: "reasoning_effort IN ('none', 'minimal', 'low', 'medium', 'high', 'max')"
           )

    create constraint(:threads, :threads_generation_nonnegative_check, check: "generation >= 0")

    create constraint(:threads, :threads_event_count_nonnegative_check, check: "event_count >= 0")

    # An open thread has not finished; a terminal thread has. Both halves are
    # enforced, so a report cannot appear on a live thread and cannot be
    # missing from a dead one.
    create constraint(:threads, :threads_terminal_shape_check,
             check: """
             (status = 'open' AND completed_at IS NULL AND report IS NULL)
             OR (status <> 'open' AND completed_at IS NOT NULL AND report IS NOT NULL)
             """
           )

    create table(:thread_events) do
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false
      add :schema, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :emitted_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:thread_events, [:thread_id, :id])

    create constraint(:thread_events, :thread_events_schema_check,
             check: "schema = 'openagents.thread.event.v1'"
           )

    create constraint(:thread_events, :thread_events_payload_bound_check,
             check: "octet_length(payload::text) BETWEEN 2 AND 16384"
           )
  end
end
