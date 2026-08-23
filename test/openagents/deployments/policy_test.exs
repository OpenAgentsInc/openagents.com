defmodule OpenAgents.Deployments.PolicyTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Deployments.Approval
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Deployments.Environment
  alias OpenAgents.Deployments.Policy
  alias OpenAgents.Deployments.Protection
  alias OpenAgents.Deployments.Request

  @commit String.duplicate("ab", 20)
  @artifact "sha256:" <> String.duplicate("c", 64)
  # A Wednesday, 12:00 UTC.
  @now ~U[2026-08-19 12:00:00Z]

  describe "source rules" do
    test "an unrestricted policy admits any ref" do
      assert {:admit, "queued", _explanation} = evaluate(%{}, %{})
    end

    test "a branch outside the allowed list is blocked" do
      protection = %{allowed_branches: ["main", "release/*"]}

      assert {:admit, "queued", _} = evaluate(protection, %{source_ref: "refs/heads/main"})
      assert {:admit, "queued", _} = evaluate(protection, %{source_ref: "refs/heads/release/1.2"})

      assert {:deny, "source_ref_not_allowed", _} =
               evaluate(protection, %{source_ref: "refs/heads/release-escape"})

      assert {:deny, "source_ref_not_allowed", _} =
               evaluate(protection, %{source_ref: "refs/tags/v1.0.0"})
    end

    test "a tag policy admits tags and refuses branches" do
      protection = %{allowed_tags: ["v*"]}

      assert {:admit, "queued", _} = evaluate(protection, %{source_ref: "refs/tags/v1.0.0"})

      assert {:deny, "source_ref_not_allowed", _} =
               evaluate(protection, %{source_ref: "refs/heads/main"})
    end

    test "a source workflow outside the allowed list is blocked" do
      protection = %{allowed_workflows: ["deploy.yml"]}

      assert {:admit, "queued", _} = evaluate(protection, %{source_workflow: "deploy.yml"})

      assert {:deny, "source_workflow_not_allowed", _} =
               evaluate(protection, %{source_workflow: "pull-request.yml"})
    end
  end

  describe "freeze and windows" do
    test "a freeze blocks with its reason preserved" do
      assert {:deny, "frozen", explanation} =
               evaluate(%{frozen: true, freeze_reason: "incident 42"}, %{})

      entry = Enum.find(explanation, &(&1["rule"] == "freeze"))
      assert entry["detail"]["freeze_reason"] == "incident 42"
    end

    test "a window admits inside its hours and blocks outside them" do
      protection = %{window_weekdays: [3], window_start_minute: 600, window_end_minute: 1_020}

      assert {:admit, "queued", _} = evaluate(protection, %{}, @now)
      assert {:deny, "outside_window", _} = evaluate(protection, %{}, ~U[2026-08-19 18:00:00Z])
      assert {:deny, "outside_window", _} = evaluate(protection, %{}, ~U[2026-08-20 12:00:00Z])
    end
  end

  describe "artifact age" do
    test "an artifact older than the limit is blocked" do
      protection = %{maximum_artifact_age_seconds: 3_600}

      assert {:admit, "queued", _} =
               evaluate(
                 protection,
                 %{artifact_created_at: DateTime.add(@now, -60, :second)},
                 @now
               )

      assert {:deny, "artifact_too_old", _} =
               evaluate(
                 protection,
                 %{artifact_created_at: DateTime.add(@now, -7_200, :second)},
                 @now
               )
    end

    test "an unknown artifact age is blocked rather than assumed fresh" do
      assert {:deny, "artifact_age_unknown", _} =
               evaluate(%{maximum_artifact_age_seconds: 3_600}, %{artifact_created_at: nil}, @now)
    end
  end

  describe "required checks" do
    test "a missing check keeps the run checking" do
      assert {:admit, "checking", _} = evaluate(%{required_checks: ["build"]}, %{})
    end

    test "a check for other bytes does not count" do
      other = check(%{commit_sha: String.duplicate("ef", 20)})

      assert {:admit, "checking", _} = evaluate(%{required_checks: ["build"]}, %{}, @now, [other])
    end

    test "a green check for the exact bytes admits the run" do
      assert {:admit, "queued", _} =
               evaluate(%{required_checks: ["build"]}, %{}, @now, [check(%{})])
    end

    test "a pending check keeps the run checking" do
      assert {:admit, "checking", _} =
               evaluate(%{required_checks: ["build"]}, %{}, @now, [check(%{status: "pending"})])
    end

    test "a failed check denies the run" do
      assert {:deny, "checks_failed", _} =
               evaluate(%{required_checks: ["build"]}, %{}, @now, [check(%{status: "failed"})])
    end

    test "a check past its own validity is expired, not green" do
      expired = check(%{valid_until: DateTime.add(@now, -1, :second)})

      assert {:deny, "checks_expired", _} =
               evaluate(%{required_checks: ["build"]}, %{}, @now, [expired])
    end

    test "a check older than the policy validity window is expired" do
      stale = check(%{updated_at: DateTime.add(@now, -7_200, :second)})
      protection = %{required_checks: ["build"], check_validity_seconds: 3_600}

      assert {:deny, "checks_expired", _} = evaluate(protection, %{}, @now, [stale])
    end
  end

  describe "required approvals" do
    test "a run without its approvals waits" do
      assert {:admit, "waiting_for_approval", _} = evaluate(%{required_approvals: 1}, %{})
    end

    test "approvals for other bytes do not count" do
      approvals = [approval(%{request_digest: "other-digest"})]

      assert {:admit, "waiting_for_approval", _} =
               evaluate(%{required_approvals: 1}, %{}, @now, [], approvals)
    end

    test "one approval for the exact request admits the run" do
      assert {:admit, "queued", _} =
               evaluate(%{required_approvals: 1}, %{}, @now, [], [approval(%{})])
    end

    test "one rejection denies the run even alongside approvals" do
      approvals = [approval(%{}), approval(%{decision: "rejected"})]

      assert {:deny, "rejected", _} = evaluate(%{required_approvals: 1}, %{}, @now, [], approvals)
    end

    test "a denial explains every rule it considered" do
      assert {:deny, _reason, explanation} = evaluate(%{frozen: true}, %{})

      assert Enum.map(explanation, & &1["rule"]) == [
               "allowed_sources",
               "freeze",
               "deployment_window",
               "artifact_age",
               "required_checks",
               "required_approvals"
             ]
    end
  end

  describe "initial state" do
    test "an environment with required checks starts a run in checking" do
      assert Policy.initial_state(environment(%{required_checks: ["build"]})) == "checking"
      assert Policy.initial_state(environment(%{})) == "requested"
    end
  end

  defp evaluate(protection, request, now \\ @now, checks \\ [], approvals \\ []) do
    Policy.evaluate(environment(protection), request(request), checks, approvals, now)
  end

  defp environment(protection) do
    %Environment{
      name: "production",
      kind: "production",
      provider: "fake",
      protection: struct!(%Protection{}, protection)
    }
  end

  defp request(attrs) do
    struct!(
      %Request{
        commit_sha: @commit,
        artifact_digest: @artifact,
        source_ref: "refs/heads/main",
        source_workflow: "deploy.yml",
        principal_type: "user",
        request_digest: "request-digest",
        requested_by_user_id: Ecto.UUID.generate()
      },
      attrs
    )
  end

  defp check(attrs) do
    struct!(
      %CheckResult{
        name: "build",
        commit_sha: @commit,
        artifact_digest: @artifact,
        status: "succeeded",
        updated_at: @now
      },
      attrs
    )
  end

  defp approval(attrs) do
    struct!(
      %Approval{
        decision: "approved",
        rule: "required_approvals",
        request_digest: "request-digest",
        approver_user_id: Ecto.UUID.generate(),
        decided_at: @now
      },
      attrs
    )
  end
end
