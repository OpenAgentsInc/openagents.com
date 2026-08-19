defmodule OpenAgents.Collective.Reviewer do
  @moduledoc "Pinned independent evaluation gate for generalized collective candidates."

  import Ecto.Query

  alias OpenAgents.Collective.{Candidate, ConsentReceipt, GeneralizationReceipt, ReviewReceipt}
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy %{
    "id" => "sarah.collective.independent_review.v1",
    "version" => 1,
    "thresholds" => %{"novelty" => 0.6, "utility" => 0.7},
    "blocking" => ~w(privacy safety regression compatibility authority)
  }
  @categorical %{
    "privacy" => "passed",
    "safety" => "passed",
    "regression" => "passed",
    "compatibility" => "passed",
    "authority" => "no_expansion"
  }
  @dimension_keys ~w(privacy safety regression compatibility authority novelty utility)

  @spec review(Visitor.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: ReviewReceipt.t()}} | {:error, term()}
  def review(%Visitor{} = owner, candidate_id, reviewer, evaluation)
      when is_map(reviewer) and is_map(evaluation) do
    with :ok <- validate_reviewer(reviewer),
         {:ok, normalized} <- validate_evaluation(evaluation) do
      Repo.transaction(fn ->
        candidate = lock_candidate(owner.id, candidate_id)
        consent = Repo.get_for_update!(ConsentReceipt, candidate.consent_receipt_id)
        generalization = Repo.get_by!(GeneralizationReceipt, candidate_id: candidate.id)

        cond do
          consent.status != "active" ->
            Repo.rollback(:contribution_consent_not_active)

          candidate.status not in ~w(generalized reviewed review_rejected) ->
            Repo.rollback(:candidate_not_generalized)

          generalization.status != "generalized" ->
            Repo.rollback(:candidate_generalization_rejected)

          generalization.reviewer_actor_id == "unrecorded:v1" ->
            Repo.rollback(:generalization_reviewer_unbound)

          generalization.reviewer_actor_id == reviewer.actor_id ->
            Repo.rollback(:independent_reviewer_required)

          true ->
            existing_or_review(candidate, generalization, reviewer, normalized)
        end
      end)
      |> transaction_result()
    end
  end

  def review(%Visitor{}, _candidate_id, _reviewer, _evaluation),
    do: {:error, :collective_evaluator_required}

  defp existing_or_review(candidate, generalization, reviewer, evaluation) do
    case Repo.get_by(ReviewReceipt, candidate_id: candidate.id) do
      %ReviewReceipt{} = receipt -> %{candidate: candidate, receipt: receipt}
      nil -> persist_review(candidate, generalization, reviewer, evaluation)
    end
  end

  defp persist_review(candidate, generalization, reviewer, evaluation) do
    policy = Map.put(@policy, "digest", Canonical.digest!(@policy))
    {decision, reason_codes} = decision(evaluation.dimensions)

    evaluation_digest =
      Canonical.digest!(%{
        "candidate_digest" => generalization.candidate_digest,
        "output_digest" => generalization.output_digest,
        "evaluator_artifact_digest" => evaluation.evaluator_artifact_digest,
        "dataset_digest" => evaluation.dataset_digest,
        "policy_digest" => policy["digest"],
        "dimensions" => evaluation.dimensions
      })

    receipt =
      %ReviewReceipt{}
      |> ReviewReceipt.changeset(%{
        candidate_id: candidate.id,
        generalization_receipt_id: generalization.id,
        decision: decision,
        reason_codes: reason_codes,
        evaluator_artifact_ref: evaluation.evaluator_artifact_ref,
        evaluator_artifact_digest: evaluation.evaluator_artifact_digest,
        dataset_ref: evaluation.dataset_ref,
        dataset_digest: evaluation.dataset_digest,
        policy_id: policy["id"],
        policy_version: policy["version"],
        policy_digest: policy["digest"],
        candidate_digest: generalization.candidate_digest,
        evaluation_digest: evaluation_digest,
        dimensions: evaluation.dimensions,
        reviewer_actor_id: reviewer.actor_id,
        reviewer_auth_method: reviewer.auth_method
      })
      |> insert_or_rollback()

    review_ref = "collective-review:v1:#{receipt.id}:#{receipt.evaluation_digest}"

    candidate =
      candidate
      |> Candidate.review_changeset(%{
        status: if(decision == "passed", do: "reviewed", else: "review_rejected"),
        evaluator_ref: evaluation.evaluator_artifact_ref,
        review_refs: candidate.review_refs ++ [review_ref]
      })
      |> update_or_rollback()

    %{candidate: candidate, receipt: receipt}
  end

  defp decision(dimensions) do
    categorical_failures =
      @categorical
      |> Enum.reject(fn {dimension, expected} -> dimensions[dimension] == expected end)
      |> Enum.map(fn {dimension, _expected} -> "#{dimension}_blocked" end)

    score_failures =
      []
      |> maybe_add(
        dimensions["novelty"] < @policy["thresholds"]["novelty"],
        "novelty_below_threshold"
      )
      |> maybe_add(
        dimensions["utility"] < @policy["thresholds"]["utility"],
        "utility_below_threshold"
      )

    case Enum.sort(categorical_failures ++ score_failures) do
      [] -> {"passed", []}
      reasons -> {"rejected", reasons}
    end
  end

  defp maybe_add(reasons, true, reason), do: [reason | reasons]
  defp maybe_add(reasons, false, _reason), do: reasons

  defp validate_evaluation(evaluation) do
    dimensions = evaluation["dimensions"]

    cond do
      not pinned_ref?(evaluation["evaluator_artifact_ref"], "module:") ->
        {:error, :evaluator_artifact_ref_invalid}

      not digest?(evaluation["evaluator_artifact_digest"]) ->
        {:error, :evaluator_artifact_digest_invalid}

      not pinned_ref?(evaluation["dataset_ref"], "dataset:") ->
        {:error, :evaluation_dataset_ref_invalid}

      not digest?(evaluation["dataset_digest"]) ->
        {:error, :evaluation_dataset_digest_invalid}

      not is_map(dimensions) or Enum.sort(Map.keys(dimensions)) != Enum.sort(@dimension_keys) ->
        {:error, :evaluation_dimensions_invalid}

      not Enum.all?(@categorical, fn {key, expected} ->
        value = dimensions[key]
        is_binary(value) and byte_size(value) <= 32 and (value == expected or value == "blocked")
      end) ->
        {:error, :evaluation_dimensions_invalid}

      not score?(dimensions["novelty"]) or not score?(dimensions["utility"]) ->
        {:error, :evaluation_dimensions_invalid}

      true ->
        {:ok,
         %{
           evaluator_artifact_ref: evaluation["evaluator_artifact_ref"],
           evaluator_artifact_digest: evaluation["evaluator_artifact_digest"],
           dataset_ref: evaluation["dataset_ref"],
           dataset_digest: evaluation["dataset_digest"],
           dimensions: Map.take(dimensions, @dimension_keys)
         }}
    end
  end

  defp validate_reviewer(%{
         authenticated: true,
         role: "collective_evaluator",
         actor_id: actor_id,
         auth_method: auth_method
       })
       when is_binary(actor_id) and byte_size(actor_id) in 1..256 and
              is_binary(auth_method) and byte_size(auth_method) in 1..128,
       do: :ok

  defp validate_reviewer(_reviewer), do: {:error, :collective_evaluator_required}

  defp lock_candidate(owner_id, candidate_id) do
    Repo.one(
      from(candidate in Candidate,
        where: candidate.id == ^candidate_id and candidate.visitor_id == ^owner_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:candidate_not_found)
  end

  defp pinned_ref?(value, prefix),
    do: is_binary(value) and byte_size(value) in 1..256 and String.starts_with?(value, prefix)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp score?(value), do: is_number(value) and value >= 0 and value <= 1

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
