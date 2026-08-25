defmodule OpenAgents.Repo.Migrations.AddParentAndReportTypeToThreads do
  @moduledoc """
  A thread may name a parent thread and a terminal thread now carries a typed
  report. The parent reference is nullable: a thread without a parent is a root
  thread. A child thread is otherwise a normal thread, so the owner, budget,
  and lifecycle are all the same. The report type is required once a thread
  terminates and null while it is open.
  """

  use Ecto.Migration

  def up do
    alter table(:threads) do
      add :parent_thread_id,
          references(:threads, type: :binary_id, on_delete: :delete_all)

      add :report_type, :string
    end

    create index(:threads, [:parent_thread_id])

    execute("""
    UPDATE threads
    SET report_type = 'outcome'
    WHERE status <> 'open' AND report_type IS NULL
    """)

    drop constraint(:threads, :threads_terminal_shape_check)

    create constraint(:threads, :threads_terminal_shape_check,
             check: """
             (status = 'open' AND completed_at IS NULL AND report IS NULL AND report_type IS NULL)
             OR (status <> 'open' AND completed_at IS NOT NULL AND report IS NOT NULL AND report_type IS NOT NULL)
             """
           )

    create constraint(:threads, :threads_no_self_parent,
             check: "parent_thread_id IS NULL OR parent_thread_id <> id"
           )

    create constraint(:threads, :threads_report_type_bound_check,
             check: "report_type IS NULL OR octet_length(report_type) BETWEEN 1 AND 80"
           )
  end

  def down do
    drop constraint(:threads, :threads_report_type_bound_check)
    drop constraint(:threads, :threads_no_self_parent)
    drop constraint(:threads, :threads_terminal_shape_check)

    create constraint(:threads, :threads_terminal_shape_check,
             check: """
             (status = 'open' AND completed_at IS NULL AND report IS NULL)
             OR (status <> 'open' AND completed_at IS NOT NULL AND report IS NOT NULL)
             """
           )

    drop index(:threads, [:parent_thread_id])

    alter table(:threads) do
      remove :report_type
      remove :parent_thread_id
    end
  end
end
