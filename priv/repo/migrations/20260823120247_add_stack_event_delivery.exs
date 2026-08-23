defmodule OpenAgents.Repo.Migrations.AddStackEventDelivery do
  use Ecto.Migration

  def change do
    alter table(:pull_request_stack_events) do
      add :delivered_at, :utc_datetime_usec
    end

    create index(:pull_request_stack_events, [:inserted_at],
             where: "delivered_at IS NULL",
             name: :pull_request_stack_events_undelivered_index
           )
  end
end
