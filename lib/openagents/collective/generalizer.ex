defmodule OpenAgents.Collective.Generalizer do
  @moduledoc "Deterministic fixed-vocabulary generalizer for consented private candidates."

  import Ecto.Query

  alias OpenAgents.Collective.{Candidate, ConsentReceipt, GeneralizationReceipt}
  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.Memory.Redaction
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy %{
    "id" => "sarah.collective.privacy_generalization.v1",
    "version" => 1,
    "forbidden" =>
      ~w(identity contact secrets paths exact_quotes unique_business_context authority capability)
  }
  @generalizer %{
    "id" => "sarah.collective.fixed_vocabulary.v1",
    "version" => 1,
    "signals" => ~w(preference correction recall workflow_outcome)
  }

  @spec generalize(Visitor.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{candidate: Candidate.t(), receipt: GeneralizationReceipt.t()}}
          | {:error, term()}
  def generalize(%Visitor{} = owner, candidate_id, reviewer) when is_map(reviewer) do
    with :ok <- validate_reviewer(reviewer) do
      Repo.transaction(fn ->
        candidate =
          Repo.one(
            from(candidate in Candidate,
              where: candidate.id == ^candidate_id and candidate.visitor_id == ^owner.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:candidate_not_found)

        consent = Repo.get_for_update!(ConsentReceipt, candidate.consent_receipt_id)

        cond do
          consent.status != "active" -> Repo.rollback(:contribution_consent_not_active)
          candidate.status != "consented" -> existing_result(candidate)
          true -> generalize_locked(owner, candidate, consent, reviewer)
        end
      end)
      |> transaction_result()
    end
  end

  def generalize(%Visitor{}, _candidate_id, _reviewer),
    do: {:error, :privacy_reviewer_required}

  @spec review_projection(Visitor.t(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def review_projection(%Visitor{} = owner, candidate_id, reviewer) do
    with :ok <- validate_reviewer(reviewer),
         %Candidate{} = candidate <-
           Repo.get_by(Candidate, id: candidate_id, visitor_id: owner.id),
         %GeneralizationReceipt{} = receipt <-
           Repo.get_by(GeneralizationReceipt, candidate_id: candidate.id) do
      {:ok,
       %{
         "candidate_id" => candidate.id,
         "kind" => candidate.generalized_kind,
         "status" => candidate.status,
         "payload" => candidate.generalized_payload,
         "candidate_digest" => receipt.candidate_digest,
         "output_digest" => receipt.output_digest,
         "policy" => %{
           "id" => receipt.policy_id,
           "version" => receipt.policy_version,
           "digest" => receipt.policy_digest
         },
         "lineage" => candidate.provenance_refs,
         "reason_codes" => receipt.reason_codes
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generalize_locked(owner, candidate, consent, reviewer) do
    messages = load_sources(consent)
    source_text = Enum.map_join(messages, "\n", & &1.content)
    signal = classify_signal(source_text)

    case signal do
      nil ->
        persist_rejection(
          owner,
          candidate,
          consent,
          reviewer,
          "insufficient_generalizable_signal"
        )

      signal ->
        persist_generalization(owner, candidate, consent, reviewer, signal, source_text)
    end
  end

  defp persist_generalization(owner, candidate, consent, reviewer, signal, source_text) do
    payload = payload(candidate.generalized_kind, signal)

    with :ok <- validate_payload(payload, source_text) do
      output_digest = Canonical.digest!(payload)
      candidate_digest = candidate_digest(candidate, consent)

      candidate =
        candidate
        |> Candidate.status_changeset(%{status: "generalized"})
        |> Ecto.Changeset.change(%{
          generalized_payload: payload,
          evaluator_ref: "collective-evaluator:pending"
        })
        |> update_or_rollback()

      receipt =
        receipt_changeset(owner, candidate, consent, reviewer, %{
          status: "generalized",
          reason_codes: redaction_reason_codes(source_text),
          risk: "low",
          utility: "sufficient",
          support_signal: signal,
          output_digest: output_digest,
          candidate_digest: candidate_digest
        })
        |> insert_or_rollback()

      %{candidate: candidate, receipt: receipt}
    else
      {:error, reason} ->
        persist_rejection(owner, candidate, consent, reviewer, Atom.to_string(reason))
    end
  end

  defp persist_rejection(owner, candidate, consent, reviewer, reason) do
    candidate_digest = candidate_digest(candidate, consent)

    candidate =
      candidate
      |> Candidate.status_changeset(%{status: "rejected"})
      |> update_or_rollback()

    receipt =
      receipt_changeset(owner, candidate, consent, reviewer, %{
        status: "rejected",
        reason_codes: [reason],
        risk: "high",
        utility: "insufficient",
        support_signal: nil,
        output_digest: nil,
        candidate_digest: candidate_digest
      })
      |> insert_or_rollback()

    %{candidate: candidate, receipt: receipt}
  end

  defp existing_result(candidate) do
    case Repo.get_by(GeneralizationReceipt, candidate_id: candidate.id) do
      nil -> Repo.rollback(:candidate_state_without_generalization_receipt)
      receipt -> %{candidate: candidate, receipt: receipt}
    end
  end

  defp receipt_changeset(owner, candidate, consent, reviewer, attributes) do
    policy = policy(@policy)
    generalizer = policy(@generalizer)

    GeneralizationReceipt.changeset(
      %GeneralizationReceipt{},
      Map.merge(attributes, %{
        candidate_id: candidate.id,
        visitor_id: owner.id,
        source_digest: consent.source_digest,
        policy_id: policy["id"],
        policy_version: policy["version"],
        policy_digest: policy["digest"],
        generalizer_id: generalizer["id"],
        generalizer_version: generalizer["version"],
        generalizer_digest: generalizer["digest"],
        source_count: length(consent.source_refs),
        reviewer_actor_id: reviewer.actor_id,
        reviewer_auth_method: reviewer.auth_method
      })
    )
  end

  defp load_sources(consent) do
    ids =
      Enum.map(consent.source_refs, fn "message:" <> id ->
        {:ok, parsed} = Ecto.UUID.cast(id)
        parsed
      end)

    Repo.all(from(message in Message, where: message.id in ^ids, order_by: [asc: message.id]))
  end

  defp classify_signal(text) do
    normalized = String.downcase(text)

    cond do
      Regex.match?(~r/\b(?:prefer|preference|like|dislike)\b/u, normalized) ->
        "preference"

      Regex.match?(~r/\b(?:correct|correction|actually|instead)\b/u, normalized) ->
        "correction"

      Regex.match?(~r/\b(?:remember|recall|earlier|before)\b/u, normalized) ->
        "recall"

      Regex.match?(~r/\b(?:worked|failed|outcome|workflow|result)\b/u, normalized) ->
        "workflow_outcome"

      true ->
        nil
    end
  end

  defp payload("evaluation_case", signal),
    do: %{
      "schema" => "sarah.collective.evaluation_case.v1",
      "pattern" => signal,
      "input" => "A de-identified #{String.replace(signal, "_", " ")} case.",
      "expected_property" => expected_property(signal)
    }

  defp payload("prompt_example", signal),
    do: %{
      "schema" => "sarah.collective.prompt_example.v1",
      "pattern" => signal,
      "prompt" => "Handle [DE_IDENTIFIED_#{String.upcase(signal)}] using the stated user intent.",
      "response_property" => expected_property(signal)
    }

  defp payload("module_pattern", signal),
    do: %{
      "schema" => "sarah.collective.module_pattern.v1",
      "pattern" => signal,
      "signature" => %{
        "input" => ["de_identified_context", "explicit_policy"],
        "output" => ["bounded_proposal", "evidence_refs"]
      }
    }

  defp payload("reusable_work_pattern", signal),
    do: %{
      "schema" => "sarah.collective.reusable_work_pattern.v1",
      "pattern" => signal,
      "approach" => "Use bounded evidence and explicit policy before proposing an action.",
      "success_property" => expected_property(signal)
    }

  defp expected_property("preference"),
    do: "Apply the explicit preference without inventing private facts."

  defp expected_property("correction"),
    do: "Honor the correction and do not repeat superseded information."

  defp expected_property("recall"),
    do: "Use bounded evidence and distinguish verified recall from uncertainty."

  defp expected_property("workflow_outcome"),
    do: "Preserve outcome evidence and avoid claiming unsupported success."

  defp validate_payload(payload, source_text) do
    encoded = Jason.encode!(payload)

    cond do
      byte_size(encoded) > 8_192 -> {:error, :generalized_payload_too_large}
      Redaction.classify(encoded) != :safe -> {:error, :generalized_payload_secret_risk}
      contact_or_identifier?(encoded) -> {:error, :generalized_payload_identity_risk}
      exact_private_quote?(encoded, source_text) -> {:error, :generalized_payload_quote_risk}
      authority_fields?(payload) -> {:error, :generalized_payload_authority_forbidden}
      true -> :ok
    end
  end

  defp contact_or_identifier?(text) do
    Regex.match?(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu, text) or
      Regex.match?(~r/\b(?:\+?\d[\d .()-]{8,}\d)\b/u, text) or
      Regex.match?(~r/https?:\/\//iu, text) or
      Regex.match?(~r/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/iu, text)
  end

  defp exact_private_quote?(payload, source_text) do
    source_fragments =
      source_text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
      |> Enum.chunk_every(4, 1, :discard)
      |> Enum.map(&Enum.join(&1, " "))
      |> Enum.filter(&(byte_size(&1) >= 20))

    normalized_payload =
      payload |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}_]+/u, " ")

    Enum.any?(source_fragments, &String.contains?(normalized_payload, &1))
  end

  defp authority_fields?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      String.downcase(to_string(key)) in ~w(authority authorities token credential executable) or
        authority_fields?(nested)
    end)
  end

  defp authority_fields?(value) when is_list(value), do: Enum.any?(value, &authority_fields?/1)
  defp authority_fields?(_value), do: false

  defp redaction_reason_codes(text) do
    reasons =
      case Redaction.classify(text) do
        :safe -> []
        {:reject, reason} -> ["source_#{reason}_withheld"]
      end

    if contact_or_identifier?(text),
      do: Enum.uniq(reasons ++ ["source_identity_context_withheld"]),
      else: reasons
  end

  defp candidate_digest(candidate, consent) do
    Canonical.digest!(%{
      "candidate_id" => candidate.id,
      "consent_id" => consent.id,
      "source_scope_digest" => candidate.source_scope_digest,
      "source_digest" => consent.source_digest,
      "kind" => candidate.generalized_kind,
      "redaction_policy_digest" => candidate.redaction_policy_digest
    })
  end

  defp validate_reviewer(%{
         authenticated: true,
         role: "privacy_reviewer",
         actor_id: actor_id,
         auth_method: auth_method
       })
       when is_binary(actor_id) and byte_size(actor_id) in 1..256 and
              is_binary(auth_method) and byte_size(auth_method) in 1..128,
       do: :ok

  defp validate_reviewer(_reviewer), do: {:error, :privacy_reviewer_required}

  defp policy(document), do: Map.put(document, "digest", Canonical.digest!(document))

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
