defmodule OpenAgents.Repo.Migrations.CreateContinualLearningJobs do
  use Ecto.Migration

  def change do
    create table(:continual_learning_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :buyer_ref, :text, null: false
      add :buyer_class, :text, null: false
      add :objective, :text, null: false
      add :objective_version, :integer, null: false
      add :base_model_ref, :text, null: false
      add :base_model_digest, :text, null: false
      add :training_code_digest, :text, null: false
      add :configuration, :map, null: false, default: fragment("'{}'::jsonb")
      add :configuration_digest, :text, null: false
      add :datasets, {:array, :map}, null: false, default: []
      add :evaluation, :map, null: false, default: fragment("'{}'::jsonb")
      add :budget, :map, null: false, default: fragment("'{}'::jsonb")
      add :runtime_class, :text, null: false
      add :capacity_receipt, :map, null: false, default: fragment("'{}'::jsonb")
      add :stopping_policy, :map, null: false, default: fragment("'{}'::jsonb")
      add :admission_digest, :text, null: false
      add :status, :text, null: false, default: "queued"
      add :error_code, :text
      add :rounds_completed, :integer, null: false, default: 0
      add :resume_count, :integer, null: false, default: 0
      add :usage, :map, null: false, default: fragment("'{}'::jsonb")
      add :work_job_id, references(:work_jobs, type: :uuid, on_delete: :restrict)
      add :replay_of_id, references(:continual_learning_jobs, type: :uuid, on_delete: :restrict)
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:continual_learning_jobs, :continual_learning_jobs_status,
             check:
               "status IN ('queued', 'running', 'completed', 'failed', 'interrupted', 'budget_exhausted', 'cancelled')"
           )

    create constraint(:continual_learning_jobs, :continual_learning_jobs_rounds,
             check: "rounds_completed >= 0 AND resume_count >= 0"
           )

    create constraint(:continual_learning_jobs, :continual_learning_jobs_not_own_replay,
             check: "replay_of_id IS NULL OR replay_of_id <> id"
           )

    create index(:continual_learning_jobs, [:buyer_ref])
    create index(:continual_learning_jobs, [:status])
    create index(:continual_learning_jobs, [:admission_digest])
    create unique_index(:continual_learning_jobs, [:work_job_id])

    create table(:continual_learning_checkpoints, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :job_id,
          references(:continual_learning_jobs, type: :uuid, on_delete: :delete_all),
          null: false

      add :round, :integer, null: false
      add :state, :map, null: false, default: fragment("'{}'::jsonb")
      add :state_digest, :text, null: false
      add :parent_digest, :text
      add :metrics, :map, null: false, default: fragment("'{}'::jsonb")
      add :usage, :map, null: false, default: fragment("'{}'::jsonb")
      add :energy, :map, null: false, default: fragment("'{}'::jsonb")
      add :lost, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:continual_learning_checkpoints, :continual_learning_checkpoints_round,
             check: "round > 0"
           )

    create unique_index(:continual_learning_checkpoints, [:job_id, :round])
    create unique_index(:continual_learning_checkpoints, [:job_id, :state_digest])

    create table(:continual_learning_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :job_id,
          references(:continual_learning_jobs, type: :uuid, on_delete: :delete_all),
          null: false

      add :kind, :text, null: false
      add :sequence, :integer, null: false
      add :receipt_ref, :text, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :digest, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:continual_learning_receipts, :continual_learning_receipts_kind,
             check:
               "kind IN ('admission', 'usage', 'energy', 'training', 'evaluation', 'artifact', 'settlement', 'resume', 'refusal')"
           )

    create unique_index(:continual_learning_receipts, [:job_id, :sequence])
    create unique_index(:continual_learning_receipts, [:receipt_ref])
    create index(:continual_learning_receipts, [:job_id, :kind])

    create table(:continual_learning_artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :job_id,
          references(:continual_learning_jobs, type: :uuid, on_delete: :delete_all),
          null: false

      add :model_ref, :text, null: false
      add :model_digest, :text, null: false
      add :base_model_digest, :text, null: false
      add :training_code_digest, :text, null: false
      add :configuration_digest, :text, null: false
      add :dataset_bindings, {:array, :map}, null: false, default: []
      add :checkpoint_digests, {:array, :text}, null: false, default: []
      add :evaluation_result, :map, null: false, default: fragment("'{}'::jsonb")
      add :accepted_outcome, :map, null: false, default: fragment("'{}'::jsonb")
      add :settlement, :map, null: false, default: fragment("'{}'::jsonb")
      add :artifact_digest, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:continual_learning_artifacts, [:job_id])
    # Two jobs admitted under identical inputs must produce the same artifact
    # digest, so the digest is indexed for lookup and never made unique: a
    # replay that reproduces the digest is the evidence, not a conflict.
    create index(:continual_learning_artifacts, [:artifact_digest])
  end
end
