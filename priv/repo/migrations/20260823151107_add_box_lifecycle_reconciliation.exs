defmodule OpenAgents.Repo.Migrations.AddBoxLifecycleReconciliation do
  use Ecto.Migration

  def change do
    alter table(:conversation_boxes) do
      add :stop_reason, :string
      add :stop_requested_at, :utc_datetime_usec
      add :last_reconciled_at, :utc_datetime_usec
      add :reconciliation_failures, :integer, null: false, default: 0
      add :reconciliation_error, :string
      add :next_reconciliation_at, :utc_datetime_usec
      add :lifetime_seconds, :integer
      add :settled_cost_microusd, :bigint
      add :usage_settled_at, :utc_datetime_usec
    end

    create index(:conversation_boxes, [:stopped_at, :next_reconciliation_at])

    create constraint(:conversation_boxes, :conversation_boxes_usage_check,
             check:
               "reconciliation_failures >= 0 AND (lifetime_seconds IS NULL OR lifetime_seconds >= 0) AND (settled_cost_microusd IS NULL OR settled_cost_microusd >= 0)"
           )

    create table(:box_reconciliation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_box_id, :string, null: false
      add :event_type, :string, null: false
      add :reason, :string, null: false
      add :details, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec, null: false
      add :handled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:box_reconciliation_events, [:provider_box_id, :event_type])
    create index(:box_reconciliation_events, [:observed_at])
  end
end
