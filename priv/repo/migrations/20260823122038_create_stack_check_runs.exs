defmodule OpenAgents.Repo.Migrations.CreateStackCheckRuns do
  use Ecto.Migration

  def change do
    create table(:stack_check_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stack_id,
          references(:pull_request_stacks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :pull_request_id,
          references(:pull_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workflow_name, :string, null: false
      add :run_on, :string, null: false
      add :required, :boolean, null: false, default: false
      add :run_reason, :string, null: false
      add :context, :string, null: false, default: "layer"

      add :head_oid, :binary, null: false
      add :effective_base_oid, :binary, null: false
      add :workflow_definition_oid, :binary, null: false
      add :tested_oid, :binary, null: false
      add :synthetic_ref, :string

      add :state, :string, null: false, default: "pending"
      add :concluded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :stack_check_runs,
             [
               :pull_request_id,
               :workflow_name,
               :context,
               :head_oid,
               :effective_base_oid,
               :workflow_definition_oid
             ],
             name: :stack_check_runs_identity_index
           )

    create index(:stack_check_runs, [:stack_id, :state])

    create constraint(:stack_check_runs, :stack_check_runs_state_check,
             check: "state IN ('pending', 'passed', 'failed', 'stale')"
           )

    create constraint(:stack_check_runs, :stack_check_runs_context_check,
             check: "context IN ('layer', 'merge_group')"
           )

    create constraint(:stack_check_runs, :stack_check_runs_run_on_check,
             check:
               "run_on IN ('every_layer', 'top_layer_only', 'bottom_layer_only', 'changed_paths', 'merge_group_only')"
           )
  end
end
