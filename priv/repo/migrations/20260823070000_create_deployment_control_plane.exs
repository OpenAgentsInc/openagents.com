defmodule OpenAgents.Repo.Migrations.CreateDeploymentControlPlane do
  use Ecto.Migration

  def change do
    create table(:deployment_environments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false, size: 60
      add :kind, :string, null: false
      add :provider, :string, null: false
      add :provider_config, :map, null: false, default: %{}
      add :secret_references, {:array, :string}, null: false, default: []
      add :protection, :map, null: false, default: %{}
      add :retention_days, :integer, null: false, default: 90
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    # An environment name is the identity a request addresses, so one repository
    # cannot hold two `production` environments with different protection.
    create unique_index(:deployment_environments, [:repository_id, :name])

    create constraint(:deployment_environments, :deployment_environments_kind_check,
             check: "kind in ('preview', 'staging', 'production')"
           )

    create constraint(:deployment_environments, :deployment_environments_retention_check,
             check: "retention_days > 0 and retention_days <= 3650"
           )

    create table(:deployment_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment_id,
          references(:deployment_environments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :commit_sha, :string, null: false, size: 40
      add :artifact_digest, :string, null: false, size: 100
      add :artifact_created_at, :utc_datetime_usec
      add :source_ref, :string, null: false, size: 255
      add :source_workflow, :string, size: 120
      add :principal_type, :string, null: false
      add :requested_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :requested_by_grant_id, :binary_id
      add :idempotency_key, :string, null: false, size: 255
      add :request_digest, :string, null: false, size: 64
      add :input_digest, :string, null: false, size: 64
      add :requested_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Idempotency is scoped to the environment the key was spent on: replaying a
    # key with the same payload returns the original request, and replaying it
    # with different bytes is a conflict rather than a second deployment.
    create unique_index(
             :deployment_requests,
             [:repository_id, :environment_id, :idempotency_key],
             name: :deployment_requests_idempotency_index
           )

    create index(:deployment_requests, [:environment_id, :inserted_at])

    create constraint(:deployment_requests, :deployment_requests_principal_check,
             check: "principal_type in ('user', 'workflow', 'operator')"
           )

    create constraint(:deployment_requests, :deployment_requests_commit_check,
             check: "commit_sha ~ '^[0-9a-f]{40}$'"
           )

    create constraint(:deployment_requests, :deployment_requests_digest_check,
             check: "request_digest ~ '^[0-9a-f]{64}$' and input_digest ~ '^[0-9a-f]{64}$'"
           )

    create table(:deployment_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment_id,
          references(:deployment_environments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :deployment_request_id,
          references(:deployment_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :input_digest, :string, null: false, size: 64
      add :state, :string, null: false
      add :result_reason, :string, size: 80
      add :provider, :string, null: false
      add :provider_receipt, :map, null: false, default: %{}
      add :policy_explanation, {:array, :map}, null: false, default: []
      add :attempt_count, :integer, null: false, default: 0
      add :lease_owner, :string, size: 120
      add :lease_expires_at, :utc_datetime_usec
      add :cancel_requested_at, :utc_datetime_usec

      add :cancel_requested_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :superseded_by_run_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    # One admitted run per request. A retried worker resumes the existing run
    # rather than starting a second execution of the same immutable input.
    create unique_index(:deployment_runs, [:deployment_request_id])
    create index(:deployment_runs, [:environment_id, :state])
    create index(:deployment_runs, [:state, :lease_expires_at])
    create index(:deployment_runs, [:repository_id, :inserted_at])

    create constraint(:deployment_runs, :deployment_runs_state_check,
             check:
               "state in ('requested', 'checking', 'waiting_for_approval', 'queued', 'deploying', 'succeeded', 'failed', 'cancelled', 'superseded')"
           )

    create table(:deployment_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :deployment_run_id,
          references(:deployment_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :approver_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :decision, :string, null: false
      add :rule, :string, null: false, size: 80
      add :request_digest, :string, null: false, size: 64
      add :comment, :string, size: 500
      add :decided_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One decision per approver per run, so a single approver cannot satisfy a
    # two-approval policy by voting twice.
    create unique_index(:deployment_approvals, [:deployment_run_id, :approver_user_id])

    create constraint(:deployment_approvals, :deployment_approvals_decision_check,
             check: "decision in ('approved', 'rejected')"
           )

    create table(:deployment_check_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false, size: 120
      add :commit_sha, :string, null: false, size: 40
      add :artifact_digest, :string, null: false, size: 100
      add :status, :string, null: false
      add :evidence_url, :string, size: 500
      add :evidence_digest, :string, size: 64
      add :valid_until, :utc_datetime_usec
      add :published_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :published_by_grant_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    # A check result is identified by the exact bytes it examined. Publishing
    # the same check name for a different artifact adds a row instead of
    # relabelling the old evidence.
    create unique_index(
             :deployment_check_results,
             [:repository_id, :name, :commit_sha, :artifact_digest],
             name: :deployment_check_results_identity_index
           )

    create constraint(:deployment_check_results, :deployment_check_results_status_check,
             check: "status in ('pending', 'succeeded', 'failed')"
           )

    create constraint(:deployment_check_results, :deployment_check_results_commit_check,
             check: "commit_sha ~ '^[0-9a-f]{40}$'"
           )

    create table(:deployment_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :deployment_run_id,
          references(:deployment_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sequence, :integer, null: false
      add :type, :string, null: false, size: 60
      add :from_state, :string, size: 30
      add :to_state, :string, size: 30
      add :detail, :map, null: false, default: %{}
      add :actor_type, :string, null: false, size: 20
      add :actor_id, :string, size: 64
      add :occurred_at, :utc_datetime_usec, null: false

      # Append-only: an event has an insertion time and no update time, because
      # nothing may rewrite a transition after the fact.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:deployment_events, [:deployment_run_id, :sequence])
    create index(:deployment_events, [:repository_id, :inserted_at])

    create table(:deployment_workflow_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment_id,
          references(:deployment_environments, type: :binary_id, on_delete: :delete_all)

      add :token_digest, :string, null: false, size: 64
      add :audience, :string, null: false, size: 120
      add :source_ref, :string, null: false, size: 255
      add :source_workflow, :string, null: false, size: 120
      add :workflow_run_id, :string, null: false, size: 64
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deployment_workflow_grants, [:token_digest])
    create index(:deployment_workflow_grants, [:repository_id, :expires_at])
  end
end
