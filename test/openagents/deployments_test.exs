defmodule OpenAgents.DeploymentsTest do
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures
  import OpenAgents.DeploymentsFixtures

  alias OpenAgents.Deployments
  alias OpenAgents.Deployments.Principal
  alias OpenAgents.Deployments.Providers.Fake
  alias OpenAgents.Deployments.Run
  alias OpenAgents.Deployments.Worker

  setup do
    owner = repository_user_fixture("deploy-owner")
    repository = repository_with_member_fixture(owner, %{visibility: "private"}, "owner")

    %{owner: owner, repository: repository, principal: Principal.user(owner)}
  end

  describe "environments" do
    test "a writable member defines an environment and reads its protection", context do
      environment =
        environment_fixture(context.repository, context.owner, %{
          "protection" => %{"required_checks" => ["build"], "required_approvals" => 1}
        })

      assert environment.provider == "fake"
      assert environment.protection.required_checks == ["build"]

      assert {:ok, [^environment]} =
               Deployments.list_environments(context.repository, context.principal)
    end

    test "an unknown provider is refused before anything is written", context do
      assert {:error, :unknown_provider} =
               Deployments.put_environment(context.repository, context.principal, %{
                 "name" => "production",
                 "kind" => "production",
                 "provider" => "Elixir.System",
                 "protection" => %{}
               })
    end

    test "a non-member cannot define an environment", context do
      stranger = Principal.user(repository_user_fixture("deploy-stranger"))

      assert {:error, {:forbidden, :not_writable}} =
               Deployments.put_environment(context.repository, stranger, %{
                 "name" => "production",
                 "kind" => "production",
                 "provider" => "fake",
                 "protection" => %{}
               })
    end

    test "a private repository's deployments are unreadable by a non-member", context do
      environment_fixture(context.repository, context.owner)
      stranger = Principal.user(repository_user_fixture("deploy-outsider"))

      assert {:error, {:forbidden, :not_a_member}} =
               Deployments.list_environments(context.repository, stranger)
    end
  end

  describe "requesting a deployment" do
    setup context do
      %{environment: environment_fixture(context.repository, context.owner)}
    end

    test "an unprotected environment queues immediately", context do
      run = run_fixture(context.repository, context.owner)

      assert run.state == "queued"
      assert run.provider == "fake"
      assert Enum.any?(run.policy_explanation, &(&1["rule"] == "required_checks"))
    end

    test "a commit the repository never received is refused", context do
      assert {:error, :unknown_commit} =
               Deployments.request_deployment(
                 context.repository,
                 context.principal,
                 %{
                   "environment" => "production",
                   "commit_sha" => commit_sha(),
                   "artifact_digest" => artifact_digest(),
                   "source_ref" => "refs/heads/main",
                   "idempotency_key" => "unknown-commit"
                 },
                 commit_store: fn _repository, _sha -> {:error, :unknown_commit} end
               )
    end

    test "replaying an idempotency key with the same bytes returns the same run", context do
      attrs = %{"idempotency_key" => "same-key-1234"}

      first = run_fixture(context.repository, context.owner, attrs)
      second = run_fixture(context.repository, context.owner, attrs)

      assert first.id == second.id
    end

    test "replaying an idempotency key with different bytes is a conflict", context do
      run_fixture(context.repository, context.owner, %{"idempotency_key" => "conflict-1234"})

      assert {:error, :idempotency_conflict} =
               Deployments.request_deployment(
                 context.repository,
                 context.principal,
                 %{
                   "environment" => "production",
                   "commit_sha" => String.duplicate("ef", 20),
                   "artifact_digest" => artifact_digest(),
                   "source_ref" => "refs/heads/main",
                   "idempotency_key" => "conflict-1234"
                 },
                 commit_store: any_commit()
               )
    end

    test "an invalid commit sha never reaches the database", context do
      assert {:error, changeset} =
               Deployments.request_deployment(
                 context.repository,
                 context.principal,
                 %{
                   "environment" => "production",
                   "commit_sha" => "abc",
                   "artifact_digest" => artifact_digest(),
                   "source_ref" => "refs/heads/main",
                   "idempotency_key" => "bad-commit-1234"
                 },
                 commit_store: any_commit()
               )

      assert %{commit_sha: ["has invalid format"]} = errors_on(changeset)
    end

    test "a platform operator holds no tenant deployment authority", context do
      operator = Principal.operator(context.owner)

      assert {:error, {:forbidden, :operator_is_not_tenant}} =
               Deployments.request_deployment(
                 context.repository,
                 operator,
                 %{
                   "environment" => "production",
                   "commit_sha" => commit_sha(),
                   "artifact_digest" => artifact_digest(),
                   "source_ref" => "refs/heads/main",
                   "idempotency_key" => "operator-1234"
                 },
                 commit_store: any_commit()
               )
    end
  end

  describe "repository boundary" do
    setup context do
      environment_fixture(context.repository, context.owner)

      other_owner = repository_user_fixture("deploy-other-owner")
      other_repository = repository_with_member_fixture(other_owner, %{}, "owner")
      environment_fixture(other_repository, other_owner)

      %{
        run: run_fixture(context.repository, context.owner),
        other_repository: other_repository,
        other_principal: Principal.user(other_owner)
      }
    end

    test "a run cannot be read through another repository", context do
      assert {:error, {:forbidden, :cross_repository}} =
               Deployments.fetch_run(
                 context.other_repository,
                 context.other_principal,
                 context.run.id
               )
    end

    test "a run cannot be cancelled through another repository", context do
      assert {:error, {:forbidden, :cross_repository}} =
               Deployments.cancel_run(
                 context.other_repository,
                 context.other_principal,
                 context.run.id
               )
    end

    test "a run cannot be approved through another repository", context do
      assert {:error, {:forbidden, :cross_repository}} =
               Deployments.decide_run(
                 context.other_repository,
                 context.other_principal,
                 context.run.id,
                 "approved"
               )
    end

    test "an unknown run id is not found rather than forbidden", context do
      assert {:error, :run_not_found} =
               Deployments.fetch_run(context.repository, context.principal, Ecto.UUID.generate())

      assert {:error, :run_not_found} =
               Deployments.fetch_run(context.repository, context.principal, "not-a-uuid")
    end
  end

  describe "required checks" do
    setup context do
      environment =
        environment_fixture(context.repository, context.owner, %{
          "protection" => %{"required_checks" => ["build"]}
        })

      %{environment: environment, run: run_fixture(context.repository, context.owner)}
    end

    test "a run waits in checking until evidence for its exact bytes arrives", context do
      assert context.run.state == "checking"

      {:ok, _result} =
        Deployments.publish_check_result(context.repository, context.principal, %{
          "name" => "build",
          "commit_sha" => commit_sha(),
          "artifact_digest" => artifact_digest(),
          "status" => "succeeded"
        })

      assert {:ok, %Run{state: "queued"}} =
               Deployments.fetch_run(context.repository, context.principal, context.run.id)
    end

    test "a green check for different bytes does not admit the run", context do
      {:ok, _result} =
        Deployments.publish_check_result(context.repository, context.principal, %{
          "name" => "build",
          "commit_sha" => String.duplicate("ef", 20),
          "artifact_digest" => artifact_digest(),
          "status" => "succeeded"
        })

      assert {:ok, %Run{state: "checking"}} =
               Deployments.fetch_run(context.repository, context.principal, context.run.id)
    end

    test "a different artifact under the same check name is a separate result", context do
      for artifact <- [artifact_digest(), "sha256:" <> String.duplicate("d", 64)] do
        {:ok, _result} =
          Deployments.publish_check_result(context.repository, context.principal, %{
            "name" => "build",
            "commit_sha" => commit_sha(),
            "artifact_digest" => artifact,
            "status" => "succeeded"
          })
      end

      {:ok, results} =
        Deployments.list_check_results(
          context.repository,
          context.principal,
          commit_sha(),
          artifact_digest()
        )

      assert length(results) == 1
    end

    test "a failed check denies the run durably", context do
      {:ok, _result} =
        Deployments.publish_check_result(context.repository, context.principal, %{
          "name" => "build",
          "commit_sha" => commit_sha(),
          "artifact_digest" => artifact_digest(),
          "status" => "failed"
        })

      assert {:ok, %Run{state: "failed", result_reason: "checks_failed"}} =
               Deployments.fetch_run(context.repository, context.principal, context.run.id)
    end
  end

  describe "approvals" do
    setup context do
      approver = repository_user_fixture("deploy-approver")

      {:ok, _membership} =
        OpenAgents.Repositories.add_member(context.repository, approver, "maintainer")

      environment_fixture(context.repository, context.owner, %{
        "protection" => %{"required_approvals" => 1}
      })

      %{approver: approver, run: run_fixture(context.repository, context.owner)}
    end

    test "a run waits for approval and queues once another member approves", context do
      assert context.run.state == "waiting_for_approval"

      assert {:ok, %Run{state: "queued"}} =
               Deployments.decide_run(
                 context.repository,
                 Principal.user(context.approver),
                 context.run.id,
                 "approved"
               )
    end

    test "the requester cannot approve its own deployment", context do
      assert {:error, {:forbidden, :self_approval}} =
               Deployments.decide_run(
                 context.repository,
                 context.principal,
                 context.run.id,
                 "approved"
               )
    end

    test "a contributor is not an approver under the default policy", context do
      contributor = repository_user_fixture("deploy-contributor")

      {:ok, _membership} =
        OpenAgents.Repositories.add_member(context.repository, contributor, "contributor")

      assert {:error, {:forbidden, :not_an_approver}} =
               Deployments.decide_run(
                 context.repository,
                 Principal.user(contributor),
                 context.run.id,
                 "approved"
               )
    end

    test "a rejection denies the run", context do
      assert {:ok, %Run{state: "failed", result_reason: "rejected"}} =
               Deployments.decide_run(
                 context.repository,
                 Principal.user(context.approver),
                 context.run.id,
                 "rejected"
               )
    end

    test "a workflow grant cannot approve", context do
      {grant, _plaintext} = workflow_grant_fixture(context.repository, context.owner)

      assert {:error, {:forbidden, :operator_is_not_tenant}} =
               Deployments.decide_run(
                 context.repository,
                 Principal.workflow(grant),
                 context.run.id,
                 "approved"
               )
    end
  end

  describe "workflow grants" do
    setup context do
      environment_fixture(context.repository, context.owner, %{
        "name" => "preview",
        "kind" => "preview"
      })

      environment_fixture(context.repository, context.owner)

      :ok
    end

    test "a grant deploys only its own repository, environment, and source context", context do
      {grant, plaintext} =
        workflow_grant_fixture(context.repository, context.owner, %{"environment" => "preview"})

      assert {:ok, %Principal{kind: :workflow}} =
               Deployments.authenticate_workflow_grant(plaintext)

      attrs = %{
        "environment" => "preview",
        "commit_sha" => commit_sha(),
        "artifact_digest" => artifact_digest(),
        "source_ref" => "refs/heads/main",
        "source_workflow" => "deploy.yml",
        "workflow_run_id" => grant.workflow_run_id,
        "idempotency_key" => "workflow-1234"
      }

      assert {:ok, %Run{state: "queued"}} =
               Deployments.request_deployment(
                 context.repository,
                 Principal.workflow(grant),
                 attrs,
                 commit_store: any_commit()
               )

      assert {:error, {:forbidden, :cross_environment}} =
               Deployments.request_deployment(
                 context.repository,
                 Principal.workflow(grant),
                 %{attrs | "environment" => "production", "idempotency_key" => "widen-env-1234"},
                 commit_store: any_commit()
               )

      assert {:error, {:forbidden, :source_ref_mismatch}} =
               Deployments.request_deployment(
                 context.repository,
                 Principal.workflow(grant),
                 %{attrs | "source_ref" => "refs/tags/v1", "idempotency_key" => "widen-ref-1234"},
                 commit_store: any_commit()
               )

      assert {:error, {:forbidden, :source_workflow_mismatch}} =
               Deployments.request_deployment(
                 context.repository,
                 Principal.workflow(grant),
                 %{
                   attrs
                   | "source_workflow" => "other.yml",
                     "idempotency_key" => "widen-wf-1234"
                 },
                 commit_store: any_commit()
               )

      assert {:error, {:forbidden, :workflow_run_mismatch}} =
               Deployments.request_deployment(
                 context.repository,
                 Principal.workflow(grant),
                 %{
                   attrs
                   | "workflow_run_id" => "other-run",
                     "idempotency_key" => "widen-run-1234"
                 },
                 commit_store: any_commit()
               )
    end

    test "a grant cannot address another repository", context do
      {grant, _plaintext} = workflow_grant_fixture(context.repository, context.owner)

      other_owner = repository_user_fixture("deploy-grant-other")
      other_repository = repository_with_member_fixture(other_owner, %{}, "owner")
      environment_fixture(other_repository, other_owner)

      assert {:error, {:forbidden, :cross_repository}} =
               Deployments.request_deployment(
                 other_repository,
                 Principal.workflow(grant),
                 %{
                   "environment" => "production",
                   "commit_sha" => commit_sha(),
                   "artifact_digest" => artifact_digest(),
                   "source_ref" => "refs/heads/main",
                   "source_workflow" => "deploy.yml",
                   "workflow_run_id" => grant.workflow_run_id,
                   "idempotency_key" => "cross-repo-1234"
                 },
                 commit_store: any_commit()
               )
    end

    test "a revoked grant authenticates nothing", context do
      {grant, plaintext} = workflow_grant_fixture(context.repository, context.owner)

      {:ok, _revoked} =
        Deployments.revoke_workflow_grant(context.repository, context.principal, grant.id)

      assert {:error, :invalid_grant} = Deployments.authenticate_workflow_grant(plaintext)
    end

    test "a grant lifetime is clamped to the maximum", context do
      {grant, _plaintext} =
        workflow_grant_fixture(context.repository, context.owner, %{
          "lifetime_seconds" => 100_000
        })

      assert DateTime.diff(grant.expires_at, DateTime.utc_now()) <= 3_600
    end

    test "a workflow cannot cancel another workflow's run", context do
      {first, _plaintext} = workflow_grant_fixture(context.repository, context.owner)
      {second, _plaintext} = workflow_grant_fixture(context.repository, context.owner)

      {:ok, run} =
        Deployments.request_deployment(
          context.repository,
          Principal.workflow(first),
          %{
            "environment" => "production",
            "commit_sha" => commit_sha(),
            "artifact_digest" => artifact_digest(),
            "source_ref" => "refs/heads/main",
            "source_workflow" => "deploy.yml",
            "workflow_run_id" => first.workflow_run_id,
            "idempotency_key" => "grant-cancel-1234"
          },
          commit_store: any_commit()
        )

      assert {:error, {:forbidden, :cross_repository}} =
               Deployments.cancel_run(context.repository, Principal.workflow(second), run.id)

      assert {:ok, %Run{state: "cancelled"}} =
               Deployments.cancel_run(context.repository, Principal.workflow(first), run.id)
    end
  end

  describe "cancellation and supersession" do
    test "cancelling a queued run reaches a terminal state at once", context do
      environment_fixture(context.repository, context.owner)
      run = run_fixture(context.repository, context.owner)

      assert {:ok, %Run{state: "cancelled"}} =
               Deployments.cancel_run(context.repository, context.principal, run.id)
    end

    test "an optimistic precondition refuses a run that moved", context do
      environment_fixture(context.repository, context.owner)
      run = run_fixture(context.repository, context.owner)

      assert {:error, :precondition_failed} =
               Deployments.cancel_run(context.repository, context.principal, run.id,
                 if_state: "deploying"
               )
    end

    test "a terminal run cannot be cancelled again", context do
      environment_fixture(context.repository, context.owner)
      run = run_fixture(context.repository, context.owner)

      {:ok, cancelled} = Deployments.cancel_run(context.repository, context.principal, run.id)

      assert {:error, {:illegal_transition, "cancelled", "cancelled"}} =
               Deployments.cancel_run(context.repository, context.principal, cancelled.id)
    end

    test "a preview environment supersedes its older waiting runs", context do
      environment_fixture(context.repository, context.owner, %{
        "name" => "preview",
        "kind" => "preview",
        "protection" => %{"concurrency" => "supersede", "required_approvals" => 1}
      })

      older = run_fixture(context.repository, context.owner, %{"environment" => "preview"})
      newer = run_fixture(context.repository, context.owner, %{"environment" => "preview"})

      assert {:ok, %Run{state: "superseded", superseded_by_run_id: superseded_by}} =
               Deployments.fetch_run(context.repository, context.principal, older.id)

      assert superseded_by == newer.id
    end

    test "production does not supersede implicitly", context do
      environment_fixture(context.repository, context.owner, %{
        "protection" => %{"required_approvals" => 1}
      })

      older = run_fixture(context.repository, context.owner)
      _newer = run_fixture(context.repository, context.owner)

      assert {:ok, %Run{state: "waiting_for_approval"}} =
               Deployments.fetch_run(context.repository, context.principal, older.id)
    end
  end

  describe "provider execution" do
    setup context do
      environment_fixture(context.repository, context.owner)
      %{run: run_fixture(context.repository, context.owner)}
    end

    test "one queued run is claimed by exactly one worker", context do
      assert {:ok, claimed} = Deployments.claim_run("worker-a")
      assert claimed.id == context.run.id
      assert claimed.lease_owner == "worker-a"
      assert :empty = Deployments.claim_run("worker-b")
    end

    test "a successful run records a sanitized receipt and no secret values" do
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "succeeded"} = finished} =
               Worker.execute(claimed, "worker-a")

      assert finished.provider_receipt["commit_sha"] == commit_sha()
      refute Map.has_key?(finished.provider_receipt, "secrets")
      assert is_nil(finished.lease_owner)
    end

    test "a duplicate execution never deploys twice", context do
      {:ok, claimed} = Deployments.claim_run("worker-a")
      {:ok, _finished} = Worker.execute(claimed, "worker-a")

      {:ok, receipt} = Fake.receipt(context.run.id)
      assert receipt["run_id"] == context.run.id

      assert {:error, {:illegal_transition, "succeeded", _to}} =
               Worker.execute(%Run{claimed | state: "succeeded"}, "worker-a")
    end

    test "a provider failure never produces a success receipt", context do
      :ok = Fake.program(context.run.id, :fail)
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "provider_rejected"}} =
               Worker.execute(claimed, "worker-a")
    end

    test "an uncertain provider result is an explicitly uncertain failure", context do
      :ok = Fake.program(context.run.id, :uncertain)
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "provider_result_uncertain"}} =
               Worker.execute(claimed, "worker-a")
    end

    test "a provider timeout is uncertain, not successful", context do
      :ok = Fake.program(context.run.id, :hang)
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "provider_result_uncertain"}} =
               Worker.execute(claimed, "worker-a")
    end

    test "authority revoked between queueing and deploying halts the run", context do
      deployer = repository_user_fixture("deploy-losing-access")

      {:ok, _membership} =
        OpenAgents.Repositories.add_member(context.repository, deployer, "contributor")

      _run =
        run_fixture(context.repository, deployer, %{"idempotency_key" => "revoked-access-1234"})

      :ok = OpenAgents.Repositories.remove_member(context.repository, context.owner, deployer.id)

      {:ok, _cancelled} =
        Deployments.cancel_run(context.repository, context.principal, context.run.id)

      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "authority_revoked_not_writable"}} =
               Worker.execute(claimed, "worker-a")
    end

    test "a freeze applied after queueing denies the run before the provider runs", context do
      environment_fixture(context.repository, context.owner, %{
        "protection" => %{"frozen" => true, "freeze_reason" => "incident"}
      })

      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "frozen"}} =
               Worker.execute(claimed, "worker-a")

      assert Fake.receipt(context.run.id) == :error
    end

    test "cancellation requested while deploying is honored after the provider reports",
         context do
      {:ok, claimed} = Deployments.claim_run("worker-a")

      {:ok, deploying} =
        Deployments.transition(claimed, "deploying", Principal.system("worker-a"))

      {:ok, _cancelling} =
        Deployments.cancel_run(context.repository, context.principal, deploying.id)

      assert {:ok, %Run{state: "cancelled"}} =
               Deployments.finish_run(
                 OpenAgents.Repo.get!(Run, deploying.id),
                 "worker-a",
                 {:ok, %{"detail" => "deployed"}}
               )
    end
  end

  describe "recovery" do
    setup context do
      environment_fixture(context.repository, context.owner)
      %{run: run_fixture(context.repository, context.owner)}
    end

    test "a lease abandoned before the provider ran is requeued", context do
      {:ok, claimed} = Deployments.claim_run("worker-a", lease_seconds: 1)
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, %{requeued: 1, uncertain: 0}} =
               Deployments.reconcile_leases(Principal.system("reconciler"), now: later)

      assert {:ok, %Run{state: "queued", lease_owner: nil}} =
               Deployments.fetch_run(context.repository, context.principal, claimed.id)

      assert {:ok, _reclaimed} = Deployments.claim_run("worker-b")
    end

    test "a lease abandoned while deploying is uncertain, never succeeded", context do
      {:ok, claimed} = Deployments.claim_run("worker-a", lease_seconds: 1)

      {:ok, _deploying} =
        Deployments.transition(claimed, "deploying", Principal.system("worker-a"))

      later = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, %{requeued: 0, uncertain: 1}} =
               Deployments.reconcile_leases(Principal.system("reconciler"), now: later)

      assert {:ok, %Run{state: "failed", result_reason: "provider_result_uncertain"}} =
               Deployments.fetch_run(context.repository, context.principal, claimed.id)
    end

    test "a worker that lost its lease cannot renew it" do
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, _renewed} = Deployments.renew_lease(claimed, "worker-a")
      assert :error = Deployments.renew_lease(claimed, "worker-b")
    end

    test "only operator or system authority reconciles", context do
      assert {:error, {:forbidden, :not_an_operator}} =
               Deployments.reconcile_leases(context.principal)
    end
  end

  describe "events" do
    setup context do
      environment_fixture(context.repository, context.owner)
      %{run: run_fixture(context.repository, context.owner)}
    end

    test "a run's history is append-only and monotonic", context do
      {:ok, events} = Deployments.list_events(context.repository, context.principal, context.run)

      assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
      assert hd(events).type == "run_created"
    end

    test "a subscriber sees committed transitions only", context do
      :ok = Deployments.subscribe(context.run)

      {:ok, _cancelled} =
        Deployments.cancel_run(context.repository, context.principal, context.run.id)

      assert_receive {:deployment_event, %{run_id: run_id, state: "cancelled"}}
      assert run_id == context.run.id
    end

    test "event detail redacts credentials", context do
      {:ok, claimed} = Deployments.claim_run("worker-a")

      {:ok, _failed} =
        Deployments.finish_run(claimed, "worker-a", {:error, "Bearer sk-secret-token-value"})

      {:ok, events} = Deployments.list_events(context.repository, context.principal, claimed)
      details = Enum.map(events, & &1.detail)

      refute Enum.any?(details, fn detail ->
               detail |> inspect() |> String.contains?("sk-secret-token-value")
             end)
    end

    test "a provider receipt cannot echo a resolved secret value", _context do
      receipt =
        OpenAgents.Deployments.Provider.sanitize_receipt(
          %{"echo" => "value=super-secret-value"},
          ["super-secret-value"]
        )

      assert receipt["echo"] == "value=[REDACTED_SECRET]"
    end
  end

  describe "secret boundary" do
    test "an execution resolves declared references only, and never persists them", context do
      environment =
        environment_fixture(context.repository, context.owner, %{
          "provider_config" => %{"secret_reference" => "DEPLOY_TOKEN"},
          "secret_references" => ["DEPLOY_TOKEN"]
        })

      variable =
        OpenAgents.Deployments.SecretResolver.Environment.variable_name(
          environment,
          "DEPLOY_TOKEN"
        )

      System.put_env(variable, "resolved-secret-value")
      on_exit(fn -> System.delete_env(variable) end)

      run = run_fixture(context.repository, context.owner)
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "succeeded"} = finished} = Worker.execute(claimed, "worker-a")
      assert finished.provider_receipt["secret_references_resolved"] == "DEPLOY_TOKEN"

      refute finished |> inspect(limit: :infinity) |> String.contains?("resolved-secret-value")
      assert run.id == finished.id
    end

    test "a missing secret fails the run rather than deploying without it", context do
      environment_fixture(context.repository, context.owner, %{
        "provider_config" => %{"secret_reference" => "DEPLOY_TOKEN"},
        "secret_references" => ["DEPLOY_TOKEN"]
      })

      run = run_fixture(context.repository, context.owner)
      {:ok, claimed} = Deployments.claim_run("worker-a")

      assert {:ok, %Run{state: "failed", result_reason: "secret_unavailable"}} =
               Worker.execute(claimed, "worker-a")

      assert Fake.receipt(run.id) == :error
    end

    test "a provider cannot resolve a reference the environment did not declare", context do
      environment =
        environment_fixture(context.repository, context.owner, %{
          "secret_references" => ["DECLARED_TOKEN"]
        })

      assert {:error, {:undeclared_secret_reference, "OTHER_TOKEN"}} =
               OpenAgents.Deployments.SecretResolver.resolve(environment, ["OTHER_TOKEN"])
    end
  end
end
