defmodule OpenAgents.Repo.Migrations.CreateBoxFanoutRequestsAndLabels do
  use Ecto.Migration

  def up do
    alter table(:conversation_boxes) do
      add :label, :string
    end

    execute("""
    UPDATE conversation_boxes
    SET label = 'box-' || substr(id::text, 1, 64)
    WHERE label IS NULL
    """)

    alter table(:conversation_boxes) do
      modify :label, :string, null: false
    end

    create unique_index(:conversation_boxes, [:conversation_id, :label],
             name: :conversation_boxes_active_label_index,
             where: "stopped_at IS NULL"
           )

    create table(:box_fanout_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :requesting_principal, :map, null: false
      add :requested_count, :integer, null: false
      add :budgeted, :boolean, null: false, default: false
      add :effective_limits, :map, null: false
      add :state, :string, null: false, default: "admitted"
      add :admitted_count, :integer, null: false, default: 0
      add :queued_count, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:box_fanout_requests, [:conversation_id, :inserted_at])

    create table(:box_fanout_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :request_id,
          references(:box_fanout_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :queue_sequence, :bigserial, null: false
      add :label, :string, null: false
      add :state, :string, null: false, default: "queued"
      add :queue_reason, :string

      add :conversation_box_id,
          references(:conversation_boxes, type: :binary_id, on_delete: :nilify_all)

      add :estimated_burn_rate_microusd, :integer, null: false
      add :requesting_principal, :map, null: false
      add :admitted_at, :utc_datetime_usec
      add :queued_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:box_fanout_items, [:request_id, :position])

    create unique_index(:box_fanout_items, [:conversation_id, :label],
             name: :box_fanout_items_active_label_index,
             where: "state IN ('admitted', 'queued')"
           )

    create index(:box_fanout_items, [:conversation_id, :state, :queue_sequence],
             name: :box_fanout_items_queue_index
           )

    create constraint(:box_fanout_requests, :box_fanout_requests_count_check,
             check: "requested_count > 0 AND admitted_count >= 0 AND queued_count >= 0"
           )

    create constraint(:box_fanout_items, :box_fanout_items_state_check,
             check: "state IN ('admitted', 'queued', 'refused')"
           )

    create constraint(:box_fanout_items, :box_fanout_items_cost_check,
             check: "estimated_burn_rate_microusd >= 0"
           )
  end

  def down do
    drop_if_exists table(:box_fanout_items)
    drop_if_exists table(:box_fanout_requests)

    drop_if_exists index(:conversation_boxes, [:conversation_id, :label],
                     name: :conversation_boxes_active_label_index
                   )

    alter table(:conversation_boxes) do
      remove :label
    end
  end
end
