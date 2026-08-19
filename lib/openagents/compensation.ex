defmodule OpenAgents.Compensation do
  @moduledoc "Deterministic attribution accounting without payout or custody authority."

  import Ecto.Query

  alias OpenAgents.Collective.PublicationReceipt

  alias OpenAgents.Compensation.{
    Adjustment,
    Event,
    ModuleAllocation,
    OutcomeDecision,
    PolicyReceipt,
    Share,
    Statement
  }

  alias OpenAgents.Conversations.ToolStep
  alias OpenAgents.Modules.{Artifact, LifecycleReceipt}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy_id "sarah.compensation.accounting.v1"
  @policy_rules %{
    "unit" => "accounting_credit",
    "allocation_denominator" => 1_000_000,
    "accepted_terminal_status" => "succeeded",
    "revocation" => "block_future_preserve_historical",
    "adjustments" => ~w(refund chargeback fraud_hold dispute_resolution policy_migration),
    "payout_authority" => false
  }

  @spec admit_policy(map()) :: {:ok, PolicyReceipt.t()} | {:error, term()}
  def admit_policy(operator) do
    with :ok <- validate_operator(operator) do
      rules = @policy_rules
      digest = Canonical.digest!(%{"policy_id" => @policy_id, "version" => 1, "rules" => rules})

      %PolicyReceipt{}
      |> PolicyReceipt.changeset(%{
        policy_id: @policy_id,
        version: 1,
        policy_digest: digest,
        rules: rules,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @spec register_module(PolicyReceipt.t(), Artifact.t(), [map()], map()) ::
          {:ok, [ModuleAllocation.t()]} | {:error, term()}
  def register_module(%PolicyReceipt{} = policy, %Artifact{} = artifact, allocations, operator)
      when is_list(allocations) do
    with :ok <- validate_operator(operator),
         :ok <- Artifact.validate(artifact),
         :ok <- require_admitted_artifact(artifact),
         :ok <- validate_allocations(artifact, allocations) do
      lineage_digest =
        Canonical.digest!(%{"artifact" => artifact.artifact_digest, "allocations" => allocations})

      Repo.transaction(fn ->
        allocations
        |> Enum.sort_by(& &1["contribution_ref"])
        |> Enum.map(fn allocation ->
          %ModuleAllocation{}
          |> ModuleAllocation.changeset(%{
            policy_receipt_id: policy.id,
            module_id: artifact.module_id,
            module_version: artifact.version,
            artifact_digest: artifact.artifact_digest,
            contribution_ref: allocation["contribution_ref"],
            allocation_ppm: allocation["allocation_ppm"],
            lineage_digest: lineage_digest,
            actor_id: operator.actor_id,
            approval_receipt_ref: operator.approval_receipt_ref
          })
          |> insert_or_rollback()
        end)
      end)
    end
  end

  @spec decide_outcome(Ecto.UUID.t(), map(), String.t(), String.t()) ::
          {:ok, OutcomeDecision.t()} | {:error, term()}
  def decide_outcome(step_id, reviewer, decision, reason_code) do
    with :ok <- validate_outcome_reviewer(reviewer),
         :ok <- require_member(decision, ~w(accepted rejected), :outcome_decision_invalid),
         :ok <- require_code(reason_code, :outcome_reason_invalid),
         {:ok, step} <- fetch_step(step_id),
         :ok <- require_terminal(step) do
      %OutcomeDecision{}
      |> OutcomeDecision.changeset(%{
        tool_step_id: step.id,
        invocation_key: step.invocation_key,
        outcome_receipt_ref: step.outcome_receipt_ref,
        outcome_digest: step.outcome_digest,
        decision: decision,
        reason_code: reason_code,
        actor_id: reviewer.actor_id,
        auth_method: reviewer.auth_method,
        decision_receipt_ref: reviewer.decision_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @spec account(Ecto.UUID.t(), PolicyReceipt.t()) ::
          {:ok, %{event: Event.t(), shares: [Share.t()]}} | {:error, term()}
  def account(step_id, %PolicyReceipt{} = policy) do
    Repo.transaction(fn ->
      case Repo.get_by(Event, tool_step_id: step_id) do
        %Event{} = event -> %{event: event, shares: shares(event.id)}
        nil -> account_locked(step_id, policy)
      end
    end)
    |> transaction_result()
  end

  @spec adjust(Event.t(), String.t(), map(), String.t(), integer(), String.t()) ::
          {:ok, Adjustment.t()} | {:error, term()}
  def adjust(%Event{} = event, contribution_ref, operator, kind, delta_units, reason_code) do
    with :ok <- validate_operator(operator),
         :ok <- require_member(kind, @policy_rules["adjustments"], :adjustment_kind_invalid),
         :ok <- require_nonzero_integer(delta_units),
         :ok <- require_code(reason_code, :adjustment_reason_invalid),
         {:ok, _share} <- fetch_share(event.id, contribution_ref),
         :ok <- validate_adjusted_total(event, contribution_ref, delta_units) do
      digest =
        Canonical.digest!(%{
          "event_digest" => event.event_digest,
          "contribution_ref" => contribution_ref,
          "kind" => kind,
          "delta_units" => delta_units,
          "reason_code" => reason_code,
          "receipt_ref" => operator.approval_receipt_ref
        })

      %Adjustment{}
      |> Adjustment.changeset(%{
        event_id: event.id,
        policy_receipt_id: event.policy_receipt_id,
        contribution_ref: contribution_ref,
        kind: kind,
        delta_units: delta_units,
        reason_code: reason_code,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        adjustment_receipt_ref: operator.approval_receipt_ref,
        adjustment_digest: digest
      })
      |> Repo.insert()
    end
  end

  @spec reconcile(String.t(), PolicyReceipt.t(), map()) ::
          {:ok, Statement.t()} | {:error, term()}
  def reconcile(contribution_ref, %PolicyReceipt{} = policy, operator) do
    with :ok <- validate_operator(operator),
         :ok <- require_registered_contributor(policy.id, contribution_ref) do
      cutoff = DateTime.utc_now()

      shares_query =
        from(share in Share,
          join: event in Event,
          on: event.id == share.event_id,
          where:
            share.contribution_ref == ^contribution_ref and
              event.policy_receipt_id == ^policy.id and event.inserted_at <= ^cutoff
        )

      gross = Repo.aggregate(shares_query, :sum, :allocated_units) || 0
      event_count = Repo.aggregate(shares_query, :count) || 0

      adjustments_query =
        from(adjustment in Adjustment,
          where:
            adjustment.contribution_ref == ^contribution_ref and
              adjustment.policy_receipt_id == ^policy.id and adjustment.inserted_at <= ^cutoff
        )

      adjustment_units = Repo.aggregate(adjustments_query, :sum, :delta_units) || 0

      dispute_balance =
        Repo.one(
          from(adjustment in adjustments_query,
            where: adjustment.kind in ["fraud_hold", "dispute_resolution"],
            select: sum(adjustment.delta_units)
          )
        ) || 0

      disputed = dispute_balance < 0

      projection = %{
        "policy_digest" => policy.policy_digest,
        "contribution_ref" => contribution_ref,
        "cutoff_at" => DateTime.to_iso8601(cutoff),
        "gross_units" => gross,
        "adjustment_units" => adjustment_units,
        "net_units" => gross + adjustment_units,
        "event_count" => event_count,
        "state" => if(disputed, do: "disputed", else: "reconciled"),
        "payout_authority" => false
      }

      %Statement{}
      |> Statement.changeset(%{
        policy_receipt_id: policy.id,
        contribution_ref: contribution_ref,
        cutoff_at: cutoff,
        gross_units: gross,
        adjustment_units: adjustment_units,
        net_units: gross + adjustment_units,
        event_count: event_count,
        state: projection["state"],
        statement_digest: Canonical.digest!(projection),
        actor_id: operator.actor_id,
        statement_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @spec statement_projection(Statement.t()) :: map()
  def statement_projection(%Statement{} = statement) do
    %{
      "schema" => "sarah.compensation.statement.v1",
      "contribution_ref" => statement.contribution_ref,
      "policy_receipt_id" => statement.policy_receipt_id,
      "cutoff_at" => statement.cutoff_at,
      "gross_units" => statement.gross_units,
      "adjustment_units" => statement.adjustment_units,
      "net_units" => statement.net_units,
      "event_count" => statement.event_count,
      "state" => statement.state,
      "statement_digest" => statement.statement_digest,
      "payout_authority" => false
    }
  end

  @spec allocate_units(non_neg_integer(), [map()]) :: [map()]
  def allocate_units(units, allocations) when is_integer(units) and units >= 0 do
    sorted = Enum.sort_by(allocations, & &1.contribution_ref)

    bases =
      Enum.map(sorted, fn allocation ->
        Map.put(allocation, :allocated_units, div(units * allocation.allocation_ppm, 1_000_000))
      end)

    remainder = units - Enum.sum(Enum.map(bases, & &1.allocated_units))

    bases
    |> Enum.with_index()
    |> Enum.map(fn {allocation, index} ->
      Map.update!(allocation, :allocated_units, &(&1 + if(index < remainder, do: 1, else: 0)))
    end)
  end

  defp account_locked(step_id, policy) do
    step = Repo.get_for_update!(ToolStep, step_id)

    decision =
      Repo.get_by(OutcomeDecision, tool_step_id: step.id) ||
        Repo.rollback(:outcome_decision_missing)

    allocations =
      Repo.all(
        from(allocation in ModuleAllocation,
          where:
            allocation.policy_receipt_id == ^policy.id and allocation.module_id == ^step.module_id and
              allocation.module_version == ^step.tool_version and
              allocation.artifact_digest == ^step.module_artifact_digest,
          order_by: [asc: allocation.contribution_ref]
        )
      )

    if allocations == [], do: Repo.rollback(:module_attribution_missing)

    {classification, reason} = classify(step, decision)
    eligible_units = if classification == "eligible", do: step.cost_units, else: 0

    event_projection = %{
      "policy_digest" => policy.policy_digest,
      "module_id" => step.module_id,
      "module_version" => step.tool_version,
      "artifact_digest" => step.module_artifact_digest,
      "invocation_key" => step.invocation_key,
      "outcome_receipt_ref" => step.outcome_receipt_ref,
      "technical_units" => step.cost_units,
      "eligible_units" => eligible_units,
      "classification" => classification,
      "reason_code" => reason
    }

    event =
      %Event{}
      |> Event.changeset(%{
        tool_step_id: step.id,
        policy_receipt_id: policy.id,
        outcome_decision_id: decision.id,
        module_id: step.module_id,
        module_version: step.tool_version,
        artifact_digest: step.module_artifact_digest,
        invocation_key: step.invocation_key,
        outcome_receipt_ref: step.outcome_receipt_ref,
        technical_units: step.cost_units,
        eligible_units: eligible_units,
        classification: classification,
        reason_code: reason,
        event_digest: Canonical.digest!(event_projection)
      })
      |> insert_or_rollback()

    shares =
      eligible_units
      |> allocate_units(
        Enum.map(allocations, &Map.take(&1, [:contribution_ref, :allocation_ppm]))
      )
      |> Enum.map(fn allocation ->
        projection = %{
          "event_digest" => event.event_digest,
          "contribution_ref" => allocation.contribution_ref,
          "allocation_ppm" => allocation.allocation_ppm,
          "allocated_units" => allocation.allocated_units
        }

        %Share{}
        |> Share.changeset(
          Map.merge(projection, %{
            "event_id" => event.id,
            "share_digest" => Canonical.digest!(projection)
          })
        )
        |> insert_or_rollback()
      end)

    %{event: event, shares: shares}
  end

  defp classify(step, decision) do
    cond do
      decision.decision != "accepted" -> {"ineligible", "outcome_rejected"}
      step.status != "succeeded" -> {"ineligible", "outcome_not_successful"}
      not step.billable or step.cost_units <= 0 -> {"ineligible", "invocation_not_billable"}
      module_revoked?(step.module_id, step.tool_version) -> {"ineligible", "module_revoked"}
      true -> {"eligible", "accepted_under_policy"}
    end
  end

  defp module_revoked?(module_id, version) do
    lifecycle =
      Repo.one(
        from(receipt in LifecycleReceipt,
          where: receipt.module_id == ^module_id and receipt.module_version == ^version,
          order_by: [desc: receipt.generation],
          limit: 1
        )
      )

    collective =
      Repo.one(
        from(receipt in PublicationReceipt,
          where: receipt.module_id == ^module_id and receipt.module_version == ^version,
          order_by: [desc: receipt.generation],
          limit: 1
        )
      )

    (lifecycle && lifecycle.to_state == "revoked") ||
      (collective && collective.state == "revoked") || false
  end

  defp validate_allocations(artifact, allocations) do
    refs = Enum.map(allocations, & &1["contribution_ref"])
    total = Enum.sum(Enum.map(allocations, &(&1["allocation_ppm"] || 0)))

    cond do
      allocations == [] or length(allocations) > 64 ->
        {:error, :module_allocations_invalid}

      length(refs) != length(Enum.uniq(refs)) ->
        {:error, :module_allocation_duplicate}

      total != 1_000_000 ->
        {:error, :module_allocation_total_invalid}

      not Enum.all?(allocations, fn allocation ->
        safe_contribution_ref?(allocation["contribution_ref"]) and
          allocation["contribution_ref"] in artifact.attribution and
          is_integer(allocation["allocation_ppm"]) and allocation["allocation_ppm"] > 0
      end) ->
        {:error, :module_allocation_lineage_invalid}

      true ->
        :ok
    end
  end

  defp validate_adjusted_total(event, contribution_ref, delta) do
    gross =
      Repo.one(
        from(share in Share,
          where: share.event_id == ^event.id and share.contribution_ref == ^contribution_ref,
          select: share.allocated_units
        )
      ) || 0

    prior =
      Repo.one(
        from(adjustment in Adjustment,
          where:
            adjustment.event_id == ^event.id and adjustment.contribution_ref == ^contribution_ref,
          select: sum(adjustment.delta_units)
        )
      ) || 0

    if gross + prior + delta >= 0, do: :ok, else: {:error, :adjustment_exceeds_allocated_units}
  end

  defp shares(event_id),
    do:
      Repo.all(
        from(share in Share,
          where: share.event_id == ^event_id,
          order_by: [asc: share.contribution_ref]
        )
      )

  defp terminal_step?(step),
    do:
      step.status in ~w(succeeded failed refused cancelled unavailable interrupted) and
        is_binary(step.outcome_receipt_ref)

  defp bounded_code?(value),
    do:
      is_binary(value) and byte_size(value) in 1..64 and
        Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, value)

  defp safe_contribution_ref?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and not String.contains?(value, "@") and
        not String.starts_with?(value, "/")

  defp validate_operator(%{
         authenticated: true,
         role: "operator",
         actor_id: actor_id,
         auth_method: auth_method,
         approval_receipt_ref: receipt
       })
       when is_binary(actor_id) and byte_size(actor_id) in 1..256 and is_binary(auth_method) and
              byte_size(auth_method) in 1..128 and is_binary(receipt) and
              byte_size(receipt) in 1..256,
       do: :ok

  defp validate_operator(_operator), do: {:error, :authenticated_operator_required}

  defp validate_outcome_reviewer(%{
         authenticated: true,
         role: "outcome_reviewer",
         actor_id: actor_id,
         auth_method: auth_method,
         decision_receipt_ref: receipt
       })
       when is_binary(actor_id) and byte_size(actor_id) in 1..256 and is_binary(auth_method) and
              byte_size(auth_method) in 1..128 and is_binary(receipt) and
              byte_size(receipt) in 1..256,
       do: :ok

  defp validate_outcome_reviewer(_reviewer), do: {:error, :outcome_reviewer_required}

  defp fetch_step(step_id) do
    case Repo.get(ToolStep, step_id) do
      %ToolStep{} = step -> {:ok, step}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp fetch_share(event_id, contribution_ref) do
    case Repo.get_by(Share, event_id: event_id, contribution_ref: contribution_ref) do
      %Share{} = share -> {:ok, share}
      nil -> {:error, :share_not_found}
    end
  end

  defp require_member(value, values, error),
    do: if(value in values, do: :ok, else: {:error, error})

  defp require_code(value, error),
    do: if(bounded_code?(value), do: :ok, else: {:error, error})

  defp require_terminal(step),
    do: if(terminal_step?(step), do: :ok, else: {:error, :invocation_not_terminal})

  defp require_nonzero_integer(value),
    do: if(is_integer(value) and value != 0, do: :ok, else: {:error, :adjustment_units_invalid})

  defp require_registered_contributor(policy_id, contribution_ref) do
    if Repo.exists?(
         from(allocation in ModuleAllocation,
           where:
             allocation.policy_receipt_id == ^policy_id and
               allocation.contribution_ref == ^contribution_ref
         )
       ),
       do: :ok,
       else: {:error, :contributor_not_registered}
  end

  defp require_admitted_artifact(artifact) do
    boot_artifact =
      Map.get(
        OpenAgents.Tools.Registry.current!().modules,
        {artifact.module_id, artifact.version}
      )

    collective =
      Repo.one(
        from(receipt in PublicationReceipt,
          where:
            receipt.module_id == ^artifact.module_id and
              receipt.module_version == ^artifact.version,
          order_by: [desc: receipt.generation],
          limit: 1
        )
      )

    cond do
      match?(%Artifact{}, boot_artifact) and
        boot_artifact.artifact_digest == artifact.artifact_digest and
          Artifact.executable?(boot_artifact) ->
        :ok

      collective && collective.state == "staged" &&
          collective.artifact_digest == artifact.artifact_digest ->
        :ok

      true ->
        {:error, :module_not_admitted_for_attribution}
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
