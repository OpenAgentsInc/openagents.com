defmodule OpenAgents.Collective.Publisher do
  @moduledoc "Operator-controlled immutable publication and revocation for reviewed candidates."

  import Ecto.Query

  alias OpenAgents.Collective.{
    Candidate,
    ConsentReceipt,
    GeneralizationReceipt,
    OperatorDecisionReceipt,
    PublicationReceipt,
    ReviewReceipt
  }

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Modules.Artifact
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Tools.Registry

  @spec publish(Visitor.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: PublicationReceipt.t()}}
          | {:error, term()}
  def publish(%Visitor{} = owner, candidate_id, operator, attributes)
      when is_map(operator) and is_map(attributes) do
    with :ok <- validate_operator(operator),
         :ok <- validate_reason(attributes["reason"]) do
      Repo.transaction(fn -> publish_locked(owner.id, candidate_id, operator, attributes) end)
      |> transaction_result()
    end
  end

  def publish(%Visitor{}, _candidate_id, _operator, _attributes),
    do: {:error, :authenticated_operator_required}

  @spec reject(Visitor.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: OperatorDecisionReceipt.t()}}
          | {:error, term()}
  def reject(%Visitor{} = owner, candidate_id, operator, attributes)
      when is_map(operator) and is_map(attributes) do
    with :ok <- validate_operator(operator),
         :ok <- validate_reason(attributes["reason"]) do
      Repo.transaction(fn ->
        candidate = lock_owned_candidate(owner.id, candidate_id)
        review = Repo.get_by!(ReviewReceipt, candidate_id: candidate.id)
        generalization = Repo.get_by!(GeneralizationReceipt, candidate_id: candidate.id)

        cond do
          candidate.status != "reviewed" ->
            Repo.rollback(:candidate_not_approved_for_publication)

          operator.actor_id in [review.reviewer_actor_id, generalization.reviewer_actor_id] ->
            Repo.rollback(:independent_operator_required)

          true ->
            receipt =
              persist_operator_decision(candidate, review, operator, attributes, "rejected")

            candidate =
              candidate
              |> Candidate.operator_rejection_changeset()
              |> update_or_rollback()

            %{candidate: candidate, receipt: receipt}
        end
      end)
      |> transaction_result()
    end
  end

  def reject(%Visitor{}, _candidate_id, _operator, _attributes),
    do: {:error, :authenticated_operator_required}

  @spec revoke(Ecto.UUID.t(), map(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: PublicationReceipt.t()}}
          | {:error, term()}
  def revoke(candidate_id, operator, attributes),
    do: retire(candidate_id, "revoke", operator, attributes)

  @spec rollback(Ecto.UUID.t(), map(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: PublicationReceipt.t()}}
          | {:error, term()}
  def rollback(candidate_id, operator, attributes),
    do: retire(candidate_id, "rollback", operator, attributes)

  @spec catalog() :: [map()]
  def catalog do
    latest_publications()
    |> Enum.filter(&(&1.state == "staged"))
    |> Enum.map(fn receipt ->
      %{
        "module_id" => receipt.module_id,
        "version" => receipt.module_version,
        "state" => receipt.state,
        "artifact_digest" => receipt.artifact_digest,
        "artifact" => receipt.artifact,
        "attribution_lineage" => receipt.attribution_lineage
      }
    end)
  end

  @spec rebuild_plan(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def rebuild_plan(candidate_id) do
    case latest_publication(candidate_id) do
      nil -> {:error, :not_found}
      receipt -> {:ok, receipt.derived_data_plan}
    end
  end

  defp publish_locked(owner_id, candidate_id, operator, attributes) do
    candidate = lock_owned_candidate(owner_id, candidate_id)
    consent = Repo.get_for_update!(ConsentReceipt, candidate.consent_receipt_id)
    generalization = Repo.get_by!(GeneralizationReceipt, candidate_id: candidate.id)
    review = Repo.get_by!(ReviewReceipt, candidate_id: candidate.id)

    cond do
      consent.status != "active" ->
        Repo.rollback(:contribution_consent_not_active)

      candidate.status != "reviewed" ->
        Repo.rollback(:candidate_not_approved_for_publication)

      review.decision != "passed" ->
        Repo.rollback(:independent_review_not_passed)

      operator.actor_id in [review.reviewer_actor_id, generalization.reviewer_actor_id] ->
        Repo.rollback(:independent_operator_required)

      Repo.exists?(
        from(receipt in PublicationReceipt, where: receipt.candidate_id == ^candidate.id)
      ) ->
        Repo.rollback(:candidate_already_published)

      Repo.exists?(
        from(receipt in OperatorDecisionReceipt, where: receipt.candidate_id == ^candidate.id)
      ) ->
        Repo.rollback(:candidate_already_decided)

      true ->
        _decision =
          persist_operator_decision(candidate, review, operator, attributes, "approved")

        persist_publication(candidate, generalization, review, operator, attributes)
    end
  end

  defp persist_publication(candidate, generalization, review, operator, attributes) do
    module_id = "sarah.collective.#{String.slice(generalization.output_digest, 0, 20)}"
    {input_schema, output_schema} = schemas(candidate.generalized_kind)
    plan = derived_data_plan(module_id, 1)

    {:ok, artifact} =
      Artifact.from_collective(%{
        module_id: module_id,
        version: 1,
        input_schema: input_schema,
        output_schema: output_schema,
        output_digest: generalization.output_digest,
        payload: candidate.generalized_payload,
        maintainer: "OpenAgents",
        review_ref: "collective-review:#{review.id}:#{review.evaluation_digest}",
        predecessor: nil,
        attribution: candidate.provenance_refs
      })

    case Registry.admit_artifact(Registry.current!(), artifact) do
      {:ok, _validated_snapshot} -> :ok
      {:error, reason} -> Repo.rollback({:module_registry_admission_failed, reason})
    end

    receipt =
      %PublicationReceipt{}
      |> PublicationReceipt.changeset(%{
        candidate_id: candidate.id,
        review_receipt_id: review.id,
        generation: 1,
        action: "publish",
        state: "staged",
        module_id: module_id,
        module_version: 1,
        artifact: Map.from_struct(artifact),
        artifact_digest: artifact.artifact_digest,
        predecessor: nil,
        attribution_lineage: candidate.provenance_refs,
        operator_actor_id: operator.actor_id,
        operator_auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref,
        reason: attributes["reason"],
        derived_data_plan: plan,
        plan_digest: Canonical.digest!(plan)
      })
      |> insert_or_rollback()

    publication_ref = "collective-publication:v1:#{receipt.id}:#{receipt.artifact_digest}"

    candidate =
      candidate
      |> Candidate.publication_changeset(%{
        status: "published",
        publication_refs: candidate.publication_refs ++ [publication_ref]
      })
      |> update_or_rollback()

    %{candidate: candidate, receipt: receipt}
  end

  defp retire(candidate_id, action, operator, attributes)
       when is_map(operator) and is_map(attributes) do
    with :ok <- validate_operator(operator),
         :ok <- validate_reason(attributes["reason"]) do
      Repo.transaction(fn -> retire_locked(candidate_id, action, operator, attributes) end)
      |> transaction_result()
    end
  end

  defp retire(_candidate_id, _action, _operator, _attributes),
    do: {:error, :authenticated_operator_required}

  defp retire_locked(candidate_id, action, operator, attributes) do
    candidate = Repo.get_for_update!(Candidate, candidate_id)
    latest = latest_publication(candidate.id) || Repo.rollback(:publication_not_found)

    cond do
      latest.state == "revoked" ->
        %{candidate: candidate, receipt: latest}

      action == "rollback" and candidate.status == "revocation_pending" ->
        Repo.rollback(:privacy_revocation_cannot_rollback)

      true ->
        review = Repo.get!(ReviewReceipt, latest.review_receipt_id)
        {:ok, artifact} = Artifact.from_map(latest.artifact)

        {:ok, revoked_artifact} =
          Artifact.transition(artifact, "revoked", predecessor: reference(artifact))

        plan = Map.put(latest.derived_data_plan, "status", "required")

        receipt =
          %PublicationReceipt{}
          |> PublicationReceipt.changeset(%{
            candidate_id: candidate.id,
            review_receipt_id: review.id,
            generation: latest.generation + 1,
            action: action,
            state: "revoked",
            module_id: latest.module_id,
            module_version: latest.module_version,
            artifact: Map.from_struct(revoked_artifact),
            artifact_digest: revoked_artifact.artifact_digest,
            predecessor: reference(artifact),
            attribution_lineage: latest.attribution_lineage,
            operator_actor_id: operator.actor_id,
            operator_auth_method: operator.auth_method,
            approval_receipt_ref: operator.approval_receipt_ref,
            reason: attributes["reason"],
            derived_data_plan: plan,
            plan_digest: Canonical.digest!(plan)
          })
          |> insert_or_rollback()

        ref = "collective-publication:v1:#{receipt.id}:#{receipt.artifact_digest}"

        candidate =
          candidate
          |> Candidate.publication_changeset(%{
            status: "revoked",
            publication_refs: candidate.publication_refs ++ [ref]
          })
          |> update_or_rollback()

        %{candidate: candidate, receipt: receipt}
    end
  end

  defp latest_publications do
    Repo.all(
      from(receipt in PublicationReceipt,
        order_by: [asc: receipt.candidate_id, desc: receipt.generation]
      )
    )
    |> Enum.uniq_by(& &1.candidate_id)
  end

  defp latest_publication(candidate_id) do
    Repo.one(
      from(receipt in PublicationReceipt,
        where: receipt.candidate_id == ^candidate_id,
        order_by: [desc: receipt.generation],
        limit: 1
      )
    )
  end

  defp lock_owned_candidate(owner_id, candidate_id) do
    Repo.one(
      from(candidate in Candidate,
        where: candidate.id == ^candidate_id and candidate.visitor_id == ^owner_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:candidate_not_found)
  end

  defp schemas("module_pattern") do
    {
      object_schema(%{
        "de_identified_context" => %{"type" => "string", "maxLength" => 4_096},
        "explicit_policy" => %{"type" => "string", "maxLength" => 1_024}
      }),
      object_schema(%{
        "bounded_proposal" => %{"type" => "string", "maxLength" => 4_096},
        "evidence_refs" => %{
          "type" => "array",
          "items" => %{"type" => "string", "maxLength" => 256},
          "maxItems" => 16
        }
      })
    }
  end

  defp schemas(_kind) do
    {
      object_schema(%{"de_identified_case" => %{"type" => "string", "maxLength" => 4_096}}),
      object_schema(%{"bounded_result" => %{"type" => "string", "maxLength" => 4_096}})
    }
  end

  defp object_schema(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
  end

  defp derived_data_plan(module_id, version) do
    %{
      "schema" => "sarah.collective.derived_data_plan.v1",
      "module_ref" => "module:#{module_id}:#{version}",
      "status" => "not_required",
      "on_revocation" => [
        "exclude_from_catalog_projection",
        "prevent_new_discovery_and_execution",
        "delete_rebuildable_search_derivatives",
        "rebuild_catalog_and_evaluation_indexes",
        "retain_bounded_audit_receipts"
      ]
    }
  end

  defp reference(artifact),
    do: %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest
    }

  defp validate_operator(%{
         authenticated: true,
         role: "operator",
         actor_id: actor_id,
         auth_method: auth_method,
         approval_receipt_ref: approval_receipt_ref
       })
       when is_binary(actor_id) and byte_size(actor_id) in 1..256 and
              is_binary(auth_method) and byte_size(auth_method) in 1..128 and
              is_binary(approval_receipt_ref) and byte_size(approval_receipt_ref) in 1..256,
       do: :ok

  defp validate_operator(_operator), do: {:error, :authenticated_operator_required}

  defp validate_reason(reason) when is_binary(reason) and byte_size(reason) in 1..1_000, do: :ok
  defp validate_reason(_reason), do: {:error, :publication_reason_invalid}

  defp persist_operator_decision(candidate, review, operator, attributes, decision) do
    %OperatorDecisionReceipt{}
    |> OperatorDecisionReceipt.changeset(%{
      candidate_id: candidate.id,
      review_receipt_id: review.id,
      decision: decision,
      candidate_digest: review.candidate_digest,
      review_digest: review.evaluation_digest,
      operator_actor_id: operator.actor_id,
      operator_auth_method: operator.auth_method,
      approval_receipt_ref: operator.approval_receipt_ref,
      reason: attributes["reason"]
    })
    |> insert_or_rollback()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
