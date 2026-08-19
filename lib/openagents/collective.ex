defmodule OpenAgents.Collective do
  @moduledoc "Private contribution-consent boundary before collective generalization."

  import Ecto.Query

  alias OpenAgents.Collective.{Candidate, ConsentReceipt}
  alias OpenAgents.Conversations.{Conversation, Message, Visitor}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @consent_policy %{
    "id" => "sarah.collective.contribution_consent.v1",
    "version" => 1,
    "withdrawal" => "before_publication_immediate_after_publication_revocation_required"
  }
  @redaction_policy %{
    "id" => "sarah.collective.redaction.v1",
    "version" => 1,
    "raw_source_copy" => "forbidden"
  }

  @spec create_candidate(Visitor.t(), map()) ::
          {:ok, %{consent: ConsentReceipt.t(), candidate: Candidate.t()}} | {:error, term()}
  def create_candidate(%Visitor{} = owner, confirmation) when is_map(confirmation) do
    with :ok <- validate_person_confirmation(confirmation),
         {:ok, conversation} <- owned_conversation(owner, confirmation["source_scope_ref"]),
         {:ok, sources} <- exact_sources(conversation, confirmation["source_refs"]),
         policy <- policy(@consent_policy),
         redaction <- policy(@redaction_policy),
         attributes <- consent_attributes(owner, conversation, sources, confirmation, policy) do
      Repo.transaction(fn ->
        consent =
          %ConsentReceipt{}
          |> ConsentReceipt.grant_changeset(attributes)
          |> insert_or_rollback()

        provenance_refs =
          sources
          |> Enum.with_index(1)
          |> Enum.map(fn {source, index} ->
            digest = Canonical.digest!(%{"message_id" => source.id, "consent_id" => consent.id})
            "collective-source:v1:#{index}:#{digest}"
          end)

        candidate =
          %Candidate{}
          |> Candidate.create_changeset(%{
            visitor_id: owner.id,
            consent_receipt_id: consent.id,
            source_scope_digest: consent.source_scope_digest,
            provenance_refs: provenance_refs,
            redaction_policy_id: redaction["id"],
            redaction_policy_version: redaction["version"],
            redaction_policy_digest: redaction["digest"],
            generalized_kind: consent.category,
            generalized_payload: nil,
            evaluator_ref: nil,
            status: "consented",
            review_refs: [],
            publication_refs: []
          })
          |> insert_or_rollback()

        %{consent: consent, candidate: candidate}
      end)
      |> transaction_result()
    end
  end

  def create_candidate(%Visitor{}, _confirmation),
    do: {:error, :contribution_confirmation_invalid}

  @spec withdraw(Visitor.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{consent: ConsentReceipt.t(), candidate: Candidate.t()}} | {:error, term()}
  def withdraw(%Visitor{} = owner, candidate_id, confirmation) when is_map(confirmation) do
    with true <- confirmation["actor_type"] == "person" || {:error, :person_confirmation_required},
         true <- confirmation["explicit"] == true || {:error, :explicit_withdrawal_required},
         reason when is_binary(reason) <- confirmation["reason"],
         true <- byte_size(reason) in 1..500 || {:error, :withdrawal_reason_invalid} do
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
          consent.status == "withdrawn" ->
            %{consent: consent, candidate: candidate}

          consent.status != "active" ->
            Repo.rollback(:consent_not_active)

          true ->
            now = DateTime.utc_now()

            consent =
              consent
              |> ConsentReceipt.withdraw_changeset(%{
                status: "withdrawn",
                withdrawn_at: now,
                withdrawal_reason: reason
              })
              |> update_or_rollback()

            candidate_status =
              if candidate.publication_refs == [], do: "withdrawn", else: "revocation_pending"

            candidate =
              candidate
              |> Candidate.status_changeset(%{status: candidate_status})
              |> update_or_rollback()

            %{consent: consent, candidate: candidate}
        end
      end)
      |> transaction_result()
    else
      false -> {:error, :contribution_withdrawal_invalid}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :withdrawal_reason_invalid}
    end
  end

  @spec list_private_candidates(Visitor.t()) :: [Candidate.t()]
  def list_private_candidates(%Visitor{id: owner_id}) do
    Repo.all(
      from(candidate in Candidate,
        where: candidate.visitor_id == ^owner_id,
        order_by: [desc: candidate.inserted_at]
      )
    )
  end

  @spec get_private_candidate(Visitor.t(), Ecto.UUID.t()) ::
          {:ok, %{candidate: Candidate.t(), consent: ConsentReceipt.t()}} | {:error, :not_found}
  def get_private_candidate(%Visitor{id: owner_id}, candidate_id) do
    case Repo.get_by(Candidate, id: candidate_id, visitor_id: owner_id) do
      nil ->
        {:error, :not_found}

      candidate ->
        {:ok,
         %{candidate: candidate, consent: Repo.get!(ConsentReceipt, candidate.consent_receipt_id)}}
    end
  end

  defp validate_person_confirmation(confirmation) do
    cond do
      confirmation["actor_type"] != "person" ->
        {:error, :person_confirmation_required}

      confirmation["explicit"] != true ->
        {:error, :explicit_contribution_consent_required}

      confirmation["confirmation_kind"] != "collective_contribution" ->
        {:error, :contribution_confirmation_kind_invalid}

      not bounded?(confirmation["confirmation_nonce"], 256) ->
        {:error, :contribution_confirmation_nonce_invalid}

      not bounded?(confirmation["category"], 64) ->
        {:error, :contribution_category_invalid}

      not bounded?(confirmation["intended_use"], 500) ->
        {:error, :contribution_use_invalid}

      not bounded?(confirmation["attribution_disclosure"], 500) ->
        {:error, :attribution_disclosure_required}

      not bounded?(confirmation["compensation_disclosure"], 500) ->
        {:error, :compensation_disclosure_required}

      true ->
        :ok
    end
  end

  defp owned_conversation(owner, "conversation:" <> conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, id} ->
        case Repo.get_by(Conversation, id: id, visitor_id: owner.id) do
          nil -> {:error, :source_scope_not_found}
          conversation -> {:ok, conversation}
        end

      :error ->
        {:error, :source_scope_invalid}
    end
  end

  defp owned_conversation(_owner, _scope), do: {:error, :source_scope_invalid}

  defp exact_sources(conversation, refs)
       when is_list(refs) and refs != [] and length(refs) <= 16 do
    sorted_refs = Enum.sort(Enum.uniq(refs))

    with true <- length(sorted_refs) == length(refs),
         {:ok, ids} <- parse_message_refs(sorted_refs) do
      messages =
        Repo.all(
          from(message in Message,
            where:
              message.conversation_id == ^conversation.id and message.id in ^ids and
                message.status == "complete",
            order_by: [asc: message.id]
          )
        )

      if length(messages) == length(ids), do: {:ok, messages}, else: {:error, :source_not_found}
    else
      false -> {:error, :source_refs_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_sources(_conversation, _refs), do: {:error, :source_refs_invalid}

  defp parse_message_refs(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn
      "message:" <> id, {:ok, ids} ->
        case Ecto.UUID.cast(id) do
          {:ok, parsed} -> {:cont, {:ok, [parsed | ids]}}
          :error -> {:halt, {:error, :source_refs_invalid}}
        end

      _ref, _ids ->
        {:halt, {:error, :source_refs_invalid}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp consent_attributes(owner, conversation, sources, confirmation, policy) do
    source_refs = sources |> Enum.map(&"message:#{&1.id}") |> Enum.sort()

    source_digest =
      sources
      |> Enum.map(&%{"id" => &1.id, "content_digest" => Canonical.sha256(&1.content)})
      |> Canonical.digest!()

    scope_digest =
      Canonical.digest!(%{"visitor_id" => owner.id, "conversation_id" => conversation.id})

    confirmation_projection = %{
      "visitor_id" => owner.id,
      "source_scope_digest" => scope_digest,
      "source_refs" => source_refs,
      "source_digest" => source_digest,
      "category" => confirmation["category"],
      "intended_use" => confirmation["intended_use"],
      "attribution_disclosure" => confirmation["attribution_disclosure"],
      "compensation_disclosure" => confirmation["compensation_disclosure"],
      "policy_digest" => policy["digest"],
      "confirmation_nonce" => confirmation["confirmation_nonce"]
    }

    %{
      visitor_id: owner.id,
      source_scope_ref: "conversation:#{conversation.id}",
      source_scope_digest: scope_digest,
      source_refs: source_refs,
      source_digest: source_digest,
      category: confirmation["category"],
      intended_use: confirmation["intended_use"],
      attribution_disclosure: confirmation["attribution_disclosure"],
      compensation_disclosure: confirmation["compensation_disclosure"],
      policy_id: policy["id"],
      policy_version: policy["version"],
      policy_digest: policy["digest"],
      confirmation_digest: Canonical.digest!(confirmation_projection),
      status: "active",
      granted_at: DateTime.utc_now()
    }
  end

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
  defp bounded?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum
end
