defmodule OpenAgents.Deployments.Policy do
  @moduledoc """
  Evaluates one environment's protection policy against one exact request.

  Evaluation is pure: it takes the environment, the request, the check results
  already published for those exact bytes, the approvals already recorded, and
  the current time, and returns the state the run may hold plus a durable
  explanation of every rule it considered.

  The explanation is the product, not a by-product. A blocked deployment that
  cannot say which rule blocked it forces an operator to guess, and a guess is
  usually "grant more authority". Explanations carry rule names, outcomes, and
  bounded details only — never a secret value, and never a provider credential.
  """

  alias OpenAgents.Deployments.Approval
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Deployments.Environment
  alias OpenAgents.Deployments.Protection
  alias OpenAgents.Deployments.Request

  @type outcome :: :satisfied | :pending | :blocked
  @type explanation :: [%{optional(String.t()) => term()}]
  @type decision ::
          {:admit, String.t(), explanation()}
          | {:deny, String.t(), explanation()}

  @doc """
  Evaluate the policy, returning the admitted state or a denial.

  `:admit` carries `"queued"` when nothing further is required, or
  `"waiting_for_approval"` when the policy needs decisions the run does not have
  yet. `:deny` carries a bounded reason such as `"frozen"` or `"checks_failed"`.
  """
  @spec evaluate(
          Environment.t(),
          Request.t(),
          [CheckResult.t()],
          [Approval.t()],
          DateTime.t()
        ) :: decision()
  def evaluate(
        %Environment{} = environment,
        %Request{} = request,
        check_results,
        approvals,
        %DateTime{} = now
      ) do
    protection = environment.protection || %Protection{}

    [
      source_rule(protection, request),
      freeze_rule(protection),
      window_rule(protection, now),
      artifact_age_rule(protection, request, now),
      checks_rule(protection, request, check_results, now),
      approvals_rule(protection, request, approvals)
    ]
    |> decide()
  end

  @doc """
  The state a run starts in, before policy has been evaluated for the first time.

  A run that has required checks starts in `checking`, so a reader can tell an
  unevaluated run from one that is genuinely waiting on nothing.
  """
  @spec initial_state(Environment.t()) :: String.t()
  def initial_state(%Environment{} = environment) do
    protection = environment.protection || %Protection{}

    if protection.required_checks == [], do: "requested", else: "checking"
  end

  defp decide(rules) do
    explanation = Enum.map(rules, fn {_outcome, entry} -> entry end)

    blocked = Enum.find(rules, fn {outcome, _entry} -> outcome == :blocked end)
    pending = Enum.find(rules, fn {outcome, _entry} -> outcome == :pending end)

    cond do
      blocked ->
        {_outcome, entry} = blocked
        {:deny, Map.fetch!(entry, "reason"), explanation}

      pending ->
        {_outcome, entry} = pending
        {:admit, pending_state(Map.fetch!(entry, "rule")), explanation}

      true ->
        {:admit, "queued", explanation}
    end
  end

  defp pending_state("required_approvals"), do: "waiting_for_approval"
  defp pending_state(_rule), do: "checking"

  defp source_rule(%Protection{} = protection, %Request{} = request) do
    cond do
      workflow_rejected?(protection, request) ->
        blocked("allowed_workflows", "source_workflow_not_allowed", %{
          "source_workflow" => request.source_workflow
        })

      ref_admitted?(protection, request.source_ref) ->
        satisfied("allowed_sources", %{"source_ref" => request.source_ref})

      true ->
        blocked("allowed_sources", "source_ref_not_allowed", %{"source_ref" => request.source_ref})
    end
  end

  defp workflow_rejected?(%Protection{allowed_workflows: []}, _request), do: false

  defp workflow_rejected?(%Protection{allowed_workflows: allowed}, %Request{} = request),
    do: request.source_workflow not in allowed

  defp ref_admitted?(%Protection{allowed_branches: [], allowed_tags: []}, _ref), do: true

  defp ref_admitted?(%Protection{} = protection, "refs/heads/" <> branch),
    do: pattern_match?(protection.allowed_branches, branch)

  defp ref_admitted?(%Protection{} = protection, "refs/tags/" <> tag),
    do: pattern_match?(protection.allowed_tags, tag)

  defp ref_admitted?(%Protection{}, _ref), do: false

  # A trailing `*` is the only wildcard: `release/*` admits a family of branches
  # without admitting `release-hotfix-escape`.
  defp pattern_match?(patterns, value) do
    Enum.any?(patterns, fn pattern ->
      case String.split(pattern, "*", parts: 2) do
        [^value] -> true
        [prefix, ""] -> String.starts_with?(value, prefix)
        _other -> false
      end
    end)
  end

  defp freeze_rule(%Protection{frozen: true} = protection) do
    blocked("freeze", "frozen", %{"freeze_reason" => protection.freeze_reason})
  end

  defp freeze_rule(%Protection{}), do: satisfied("freeze", %{})

  defp window_rule(%Protection{} = protection, now) do
    cond do
      Protection.unrestricted_window?(protection) ->
        satisfied("deployment_window", %{"window" => "unrestricted"})

      Protection.within_window?(protection, now) ->
        satisfied("deployment_window", %{"window" => "open"})

      true ->
        blocked("deployment_window", "outside_window", %{"window" => "closed"})
    end
  end

  defp artifact_age_rule(%Protection{maximum_artifact_age_seconds: nil}, _request, _now),
    do: satisfied("artifact_age", %{"limit" => "none"})

  defp artifact_age_rule(%Protection{} = protection, %Request{artifact_created_at: nil}, _now) do
    blocked("artifact_age", "artifact_age_unknown", %{
      "maximum_age_seconds" => protection.maximum_artifact_age_seconds
    })
  end

  defp artifact_age_rule(%Protection{} = protection, %Request{} = request, now) do
    age = DateTime.diff(now, request.artifact_created_at)

    if age <= protection.maximum_artifact_age_seconds do
      satisfied("artifact_age", %{"age_seconds" => age})
    else
      blocked("artifact_age", "artifact_too_old", %{"age_seconds" => age})
    end
  end

  defp checks_rule(%Protection{required_checks: []}, _request, _results, _now),
    do: satisfied("required_checks", %{"required" => []})

  defp checks_rule(%Protection{} = protection, %Request{} = request, check_results, now) do
    matching = Enum.filter(check_results, &matches_bytes?(&1, request))
    by_name = Map.new(matching, &{&1.name, &1})

    # A required check with no evidence at all is the common case, so each rule
    # is evaluated over `{name, result_or_nil}` rather than over results found.
    required = Enum.map(protection.required_checks, &{&1, by_name[&1]})

    failed = for {name, result} <- required, failed?(result), do: name
    expired = for {name, result} <- required, expired?(result, protection, now), do: name
    missing = for {name, result} <- required, awaiting?(result), do: name

    cond do
      failed != [] ->
        blocked("required_checks", "checks_failed", %{"failed" => Enum.sort(failed)})

      expired != [] ->
        blocked("required_checks", "checks_expired", %{"expired" => Enum.sort(expired)})

      missing != [] ->
        pending("required_checks", %{"awaiting" => Enum.sort(missing)})

      true ->
        satisfied("required_checks", %{"required" => Enum.sort(protection.required_checks)})
    end
  end

  # A check counts only for the exact commit and artifact it examined. This is
  # the whole defense against replaying a green result onto different bytes.
  defp matches_bytes?(%CheckResult{} = result, %Request{} = request) do
    result.commit_sha == request.commit_sha and result.artifact_digest == request.artifact_digest
  end

  defp failed?(%CheckResult{status: "failed"}), do: true
  defp failed?(_result), do: false

  defp awaiting?(%CheckResult{status: "pending"}), do: true
  defp awaiting?(%CheckResult{}), do: false
  defp awaiting?(nil), do: true

  defp expired?(%CheckResult{status: "succeeded"} = result, %Protection{} = protection, now) do
    hard_expiry =
      not is_nil(result.valid_until) and DateTime.compare(result.valid_until, now) != :gt

    policy_expiry =
      not is_nil(protection.check_validity_seconds) and
        DateTime.diff(now, result.updated_at) > protection.check_validity_seconds

    hard_expiry or policy_expiry
  end

  defp expired?(_result, _protection, _now), do: false

  defp approvals_rule(%Protection{required_approvals: required}, _request, _approvals)
       when required <= 0 do
    satisfied("required_approvals", %{"required" => 0})
  end

  defp approvals_rule(%Protection{} = protection, %Request{} = request, approvals) do
    for_bytes = Enum.filter(approvals, &(&1.request_digest == request.request_digest))
    rejected = Enum.filter(for_bytes, &(&1.decision == "rejected"))

    approved =
      for_bytes
      |> Enum.filter(&(&1.decision == "approved"))
      |> Enum.reject(&self_approval?(protection, request, &1))
      |> Enum.uniq_by(& &1.approver_user_id)

    cond do
      rejected != [] ->
        blocked("required_approvals", "rejected", %{"rejections" => length(rejected)})

      length(approved) >= protection.required_approvals ->
        satisfied("required_approvals", %{
          "required" => protection.required_approvals,
          "approved" => length(approved)
        })

      true ->
        pending("required_approvals", %{
          "required" => protection.required_approvals,
          "approved" => length(approved)
        })
    end
  end

  # Separation of duties is enforced twice: the approval endpoint refuses the
  # requester, and evaluation refuses to count such an approval even if one is
  # already on record from before the policy tightened.
  defp self_approval?(%Protection{separation_of_duties: false}, _request, _approval), do: false

  defp self_approval?(%Protection{}, %Request{requested_by_user_id: nil}, _approval), do: false

  defp self_approval?(%Protection{}, %Request{} = request, %Approval{} = approval),
    do: approval.approver_user_id == request.requested_by_user_id

  defp satisfied(rule, detail), do: {:satisfied, entry(rule, "satisfied", detail)}
  defp pending(rule, detail), do: {:pending, entry(rule, "pending", detail)}

  defp blocked(rule, reason, detail),
    do: {:blocked, Map.put(entry(rule, "blocked", detail), "reason", reason)}

  defp entry(rule, outcome, detail) do
    %{"rule" => rule, "outcome" => outcome, "detail" => detail}
  end
end
