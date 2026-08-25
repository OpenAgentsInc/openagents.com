defmodule OpenAgentsWeb.DeploymentControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  import OpenAgents.AccountsFixtures
  import OpenAgents.DeploymentsFixtures

  setup %{conn: conn} do
    # The API does not take a commit store argument, so the store is bound here.
    # Commit existence itself is proved in the context test.
    previous = Application.get_env(:openagents, :deployment_commit_store)
    Application.put_env(:openagents, :deployment_commit_store, any_commit())

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:openagents, :deployment_commit_store)
        store -> Application.put_env(:openagents, :deployment_commit_store, store)
      end
    end)

    owner = repository_user_fixture("api-deploy-owner")
    repository = repository_with_member_fixture(owner, %{visibility: "private"}, "owner")
    environment_fixture(repository, owner)

    %{
      conn: put_deployments_api_token(conn, owner),
      owner: owner,
      repository: repository,
      path: "/api/v1/repos/#{repository.owner}/#{repository.name}"
    }
  end

  describe "authentication" do
    test "a request without a credential is refused", context do
      response =
        build_conn()
        |> get("#{context.path}/deployment-environments")
        |> json_response(401)

      assert response == %{
               "error" => %{
                 "code" => "invalid_credential",
                 "message" => "Invalid deployment credential"
               }
             }
    end

    test "a forge credential does not carry deployment authority", context do
      assert build_conn()
             |> put_forge_api_token("deploy-scope-boundary", context.repository)
             |> get("#{context.path}/deployment-environments")
             |> json_response(401)
    end

    test "a workflow grant authenticates and is bound to its own repository", context do
      {grant, plaintext} = workflow_grant_fixture(context.repository, context.owner)

      other_owner = repository_user_fixture("api-deploy-other")
      other = repository_with_member_fixture(other_owner, %{}, "owner")
      environment_fixture(other, other_owner)

      response =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> post("/api/v1/repos/#{other.owner}/#{other.name}/deployments", %{
          "environment" => "production",
          "commit_sha" => commit_sha(),
          "artifact_digest" => artifact_digest(),
          "source_ref" => "refs/heads/main",
          "source_workflow" => "deploy.yml",
          "workflow_run_id" => grant.workflow_run_id,
          "idempotency_key" => "api-cross-repo-1234"
        })
        |> json_response(403)

      assert response["error"]["code"] == "forbidden"
      assert response["error"]["detail"] == "cross_repository"
    end
  end

  describe "environments" do
    test "an owner reads environments and protection", context do
      assert %{"environments" => [environment]} =
               context.conn
               |> get("#{context.path}/deployment-environments")
               |> json_response(200)

      assert environment["name"] == "production"
      assert environment["provider"] == "fake"

      assert %{"required_checks" => [], "required_approvals" => 0} =
               context.conn
               |> get("#{context.path}/deployment-environments/production/protection")
               |> json_response(200)
    end

    test "an owner updates protection", context do
      response =
        context.conn
        |> put("#{context.path}/deployment-environments/staging", %{
          "kind" => "staging",
          "provider" => "fake",
          "protection" => %{"required_checks" => ["build"], "required_approvals" => 1}
        })
        |> json_response(200)

      assert response["protection"]["required_checks"] == ["build"]
    end

    test "a secret value is never echoed back", context do
      response =
        context.conn
        |> put("#{context.path}/deployment-environments/production", %{
          "kind" => "production",
          "provider" => "fake",
          "secret_references" => ["DEPLOY_TOKEN"],
          "protection" => %{}
        })
        |> json_response(200)

      assert response["secret_references"] == ["DEPLOY_TOKEN"]
      refute Map.has_key?(response, "secrets")
    end

    test "an unreadable repository is not found rather than forbidden", context do
      stranger = repository_user_fixture("api-deploy-stranger")

      assert build_conn()
             |> put_deployments_api_token(stranger)
             |> get("#{context.path}/deployment-environments")
             |> json_response(404)
    end
  end

  describe "deployments" do
    test "creating, reading, listing, and cancelling one deployment", context do
      created =
        context.conn
        |> post("#{context.path}/deployments", deployment_body("api-create-1234"))
        |> json_response(202)

      assert created["state"] == "queued"
      assert created["request"]["commit_sha"] == commit_sha()
      assert created["environment"] == "production"

      assert %{"deployments" => [listed], "cursor" => cursor} =
               context.conn |> get("#{context.path}/deployments") |> json_response(200)

      assert listed["id"] == created["id"]
      assert cursor == created["id"]

      assert context.conn
             |> get("#{context.path}/deployments/#{created["id"]}")
             |> json_response(200)
             |> Map.fetch!("id") == created["id"]

      assert %{"state" => "cancelled"} =
               context.conn
               |> post("#{context.path}/deployments/#{created["id"]}/cancel", %{})
               |> json_response(200)
    end

    test "a replayed idempotency key with different bytes conflicts", context do
      body = deployment_body("api-conflict-1234")

      assert context.conn |> post("#{context.path}/deployments", body) |> json_response(202)

      response =
        context.conn
        |> post("#{context.path}/deployments", %{
          body
          | "commit_sha" => String.duplicate("ef", 20)
        })
        |> json_response(409)

      assert response["error"]["code"] == "idempotency_conflict"
    end

    test "a stale precondition refuses the cancellation", context do
      created =
        context.conn
        |> post("#{context.path}/deployments", deployment_body("api-precondition-1234"))
        |> json_response(202)

      response =
        context.conn
        |> post("#{context.path}/deployments/#{created["id"]}/cancel", %{
          "if_state" => "deploying"
        })
        |> json_response(409)

      assert response["error"]["code"] == "precondition_failed"
    end

    test "an invalid commit sha is a typed validation error", context do
      response =
        context.conn
        |> post("#{context.path}/deployments", %{
          deployment_body("api-invalid-1234")
          | "commit_sha" => "abc"
        })
        |> json_response(422)

      assert response["error"]["code"] == "invalid_request"
      assert response["error"]["detail"]["commit_sha"] == ["has invalid format"]
    end

    test "an unknown deployment id is not found", context do
      assert context.conn
             |> get("#{context.path}/deployments/#{Ecto.UUID.generate()}")
             |> json_response(404)
    end

    test "another repository's deployment is a cross-repository refusal", context do
      created =
        context.conn
        |> post("#{context.path}/deployments", deployment_body("api-boundary-1234"))
        |> json_response(202)

      other_owner = repository_user_fixture("api-deploy-boundary")
      other = repository_with_member_fixture(other_owner, %{}, "owner")

      response =
        build_conn()
        |> put_deployments_api_token(other_owner)
        |> get("/api/v1/repos/#{other.owner}/#{other.name}/deployments/#{created["id"]}")
        |> json_response(403)

      assert response["error"]["detail"] == "cross_repository"
    end
  end

  describe "approvals and checks" do
    setup context do
      approver = repository_user_fixture("api-deploy-approver")

      {:ok, _membership} =
        OpenAgents.Repositories.add_member(context.repository, approver, "maintainer")

      environment_fixture(context.repository, context.owner, %{
        "protection" => %{"required_checks" => ["build"], "required_approvals" => 1}
      })

      created =
        context.conn
        |> post("#{context.path}/deployments", deployment_body("api-approval-1234"))
        |> json_response(202)

      %{approver: approver, run_id: created["id"], created: created}
    end

    test "a run waits for checks, then approval, then queues", context do
      assert context.created["state"] == "checking"

      assert context.conn
             |> post("#{context.path}/deployment-checks", %{
               "name" => "build",
               "commit_sha" => commit_sha(),
               "artifact_digest" => artifact_digest(),
               "status" => "succeeded"
             })
             |> json_response(201)
             |> Map.fetch!("status") == "succeeded"

      assert %{"state" => "waiting_for_approval"} =
               context.conn
               |> get("#{context.path}/deployments/#{context.run_id}")
               |> json_response(200)

      assert %{"state" => "queued"} =
               build_conn()
               |> put_deployments_api_token(context.approver)
               |> post("#{context.path}/deployments/#{context.run_id}/approvals", %{
                 "decision" => "approved"
               })
               |> json_response(200)

      assert %{"approvals" => [approval]} =
               context.conn
               |> get("#{context.path}/deployments/#{context.run_id}/approvals")
               |> json_response(200)

      assert approval["decision"] == "approved"
    end

    test "the requester cannot approve its own run", context do
      response =
        context.conn
        |> post("#{context.path}/deployments/#{context.run_id}/approvals", %{
          "decision" => "approved"
        })
        |> json_response(403)

      assert response["error"]["detail"] == "self_approval"
    end

    test "a decision the lifecycle does not define is refused", context do
      response =
        context.conn
        |> post("#{context.path}/deployments/#{context.run_id}/approvals", %{
          "decision" => "maybe"
        })
        |> json_response(422)

      assert response["error"]["code"] == "invalid_decision"
    end
  end

  describe "events" do
    test "history is readable, ordered, and paginated by sequence", context do
      created =
        context.conn
        |> post("#{context.path}/deployments", deployment_body("api-events-1234"))
        |> json_response(202)

      assert %{"events" => events, "after_sequence" => after_sequence} =
               context.conn
               |> get("#{context.path}/deployments/#{created["id"]}/events")
               |> json_response(200)

      assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))
      assert after_sequence == length(events)

      assert %{"events" => []} =
               context.conn
               |> get("#{context.path}/deployments/#{created["id"]}/events",
                 after_sequence: to_string(after_sequence)
               )
               |> json_response(200)
    end
  end

  describe "workflow grants" do
    test "issuing returns the token once and revoking ends it", context do
      issued =
        context.conn
        |> post("#{context.path}/deployment-workflow-grants", %{
          "audience" => "openagents-deployments",
          "scopes" => ["deployments:request"],
          "source_ref" => "refs/heads/main",
          "source_workflow" => "deploy.yml",
          "workflow_run_id" => "wfr-api-1"
        })
        |> json_response(201)

      assert is_binary(issued["token"])

      assert context.conn
             |> get("#{context.path}/deployments")
             |> json_response(200)

      assert context.conn
             |> delete("#{context.path}/deployment-workflow-grants/#{issued["id"]}")
             |> json_response(200)
             |> Map.fetch!("revoked_at")

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> issued["token"])
             |> get("#{context.path}/deployments")
             |> json_response(401)
    end

    test "a grant is never issued to a non-member", context do
      stranger = repository_user_fixture("api-grant-stranger")

      assert build_conn()
             |> put_deployments_api_token(stranger)
             |> post("#{context.path}/deployment-workflow-grants", %{
               "audience" => "openagents-deployments",
               "scopes" => ["deployments:request"],
               "source_ref" => "refs/heads/main",
               "source_workflow" => "deploy.yml",
               "workflow_run_id" => "wfr-api-2"
             })
             |> json_response(404)
    end
  end

  defp deployment_body(idempotency_key) do
    %{
      "environment" => "production",
      "commit_sha" => commit_sha(),
      "artifact_digest" => artifact_digest(),
      "source_ref" => "refs/heads/main",
      "idempotency_key" => idempotency_key
    }
  end
end
