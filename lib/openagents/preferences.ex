defmodule OpenAgents.Preferences do
  @moduledoc "Governed private behavior preferences, frozen usage, and attributed outcomes."

  import Ecto.Query

  alias OpenAgents.Conversations.{Message, Turn, TurnReceipt, Visitor}

  alias OpenAgents.Preferences.{
    ActivationReceipt,
    ConfirmationReceipt,
    Observation,
    OutcomeReceipt,
    Preference,
    ReviewReceipt,
    Scope,
    Snapshot,
    SnapshotRecord
  }

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy_id "sarah.preference.policy.v1"
  @policy_version 1
  @maximum_preferences 100
  @effect_values %{
    "response_length" => ~w(concise detailed),
    "format" => ~w(bullets paragraphs),
    "tone" => ~w(direct gentle),
    "initiative" => ~w(ask_first suggest_next_steps)
  }
  @categories %{
    "response_length" => "presentation",
    "format" => "presentation",
    "tone" => "presentation",
    "initiative" => "interaction"
  }

  @spec observe(Visitor.t(), map()) :: {:ok, Observation.t()} | {:error, term()}
  def observe(%Visitor{} = owner, attributes) when is_map(attributes) do
    with {:ok, prepared} <- prepare_observation(owner, attributes) do
      Repo.insert(Observation.changeset(%Observation{}, prepared))
    end
  end

  def observe(_owner, _attributes), do: {:error, :invalid_owner_scope}

  @spec propose(Visitor.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, Preference.t()} | {:error, term()}
  def propose(%Visitor{} = owner, observation_id, effect_key, effect_value) do
    transaction(fn -> propose_locked(owner, observation_id, effect_key, effect_value, nil) end)
  end

  def propose(_owner, _observation_id, _effect_key, _effect_value),
    do: {:error, :invalid_preference_proposal}

  @spec review(Visitor.t(), Ecto.UUID.t(), pos_integer(), map()) ::
          {:ok, %{preference: Preference.t(), receipt: ReviewReceipt.t()}} | {:error, term()}
  def review(%Visitor{} = owner, preference_id, expected_generation, review)
      when is_map(review) do
    transaction(fn ->
      with {:ok, preference} <- owned_for_update(owner.id, preference_id),
           :ok <- generation_matches(preference, expected_generation),
           :ok <- require_status(preference, "candidate"),
           {:ok, decision} <- member(review["decision"], ~w(accepted rejected), :invalid_review),
           {:ok, reviewer_id} <- reviewer(review["reviewer_id"]),
           {:ok, reason_code} <- code(review["reason_code"], :invalid_review) do
        target_status = if decision == "accepted", do: "reviewed", else: "deleted"

        terminal_generation =
          if target_status == "deleted", do: next_generation!(owner.id), else: nil

        generation =
          if terminal_generation, do: terminal_generation, else: next_generation!(owner.id)

        updated =
          transition!(preference, target_status, generation,
            terminal_generation: terminal_generation
          )

        projection = %{
          "preference_id" => preference.id,
          "owner_visitor_id" => owner.id,
          "reviewer_id" => reviewer_id,
          "decision" => decision,
          "reason_code" => reason_code,
          "effect_digest" => preference.effect_digest
        }

        receipt =
          insert!(
            ReviewReceipt.changeset(%ReviewReceipt{}, %{
              preference_id: preference.id,
              owner_visitor_id: owner.id,
              reviewer_id: reviewer_id,
              decision: decision,
              reason_code: reason_code,
              effect_digest: preference.effect_digest,
              receipt_digest: Canonical.digest!(projection)
            })
          )

        %{preference: updated, receipt: receipt}
      end
    end)
  end

  @spec confirm(Visitor.t(), Ecto.UUID.t(), pos_integer(), map()) ::
          {:ok, Preference.t()} | {:error, term()}
  def confirm(%Visitor{} = owner, preference_id, expected_generation, confirmation)
      when is_map(confirmation) do
    transaction(fn ->
      with {:ok, preference} <- owned_for_update(owner.id, preference_id),
           :ok <- generation_matches(preference, expected_generation),
           :ok <- require_status(preference, "reviewed"),
           {:ok, confirmation_evidence} <-
             validate_confirmation(confirmation, preference.effect_digest),
           generation <- next_generation!(owner.id) do
        projection = %{
          "preference_id" => preference.id,
          "owner_visitor_id" => owner.id,
          "kind" => confirmation_evidence.kind,
          "evidence_ref" => confirmation_evidence.ref,
          "effect_digest" => preference.effect_digest
        }

        receipt =
          insert!(
            ConfirmationReceipt.changeset(
              %ConfirmationReceipt{},
              Map.put(projection, "receipt_digest", Canonical.digest!(projection))
            )
          )

        transition!(preference, "confirmed", generation,
          confirmation_ref: "preference-confirmation:v1:#{receipt.id}"
        )
      end
    end)
  end

  @spec activate(Visitor.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, %{preference: Preference.t(), receipt: ActivationReceipt.t()}} | {:error, term()}
  def activate(%Visitor{} = owner, preference_id, expected_generation) do
    transaction(fn ->
      with {:ok, preference} <- owned_for_update(owner.id, preference_id),
           :ok <- generation_matches(preference, expected_generation),
           :ok <- require_status(preference, "confirmed"),
           :ok <- require_fresh(preference),
           :ok <- require_no_active_effect(owner.id, preference.effect_key),
           generation <- next_generation!(owner.id) do
        updated = transition!(preference, "active", generation, active_generation: generation)

        projection = %{
          "preference_id" => preference.id,
          "owner_visitor_id" => owner.id,
          "scope_generation" => generation,
          "confirmation_ref" => preference.confirmation_ref,
          "effect_digest" => preference.effect_digest,
          "policy_id" => preference.policy_id,
          "policy_version" => preference.policy_version
        }

        receipt =
          insert!(
            ActivationReceipt.changeset(%ActivationReceipt{}, %{
              preference_id: preference.id,
              owner_visitor_id: owner.id,
              scope_generation: generation,
              confirmation_ref: preference.confirmation_ref,
              effect_digest: preference.effect_digest,
              policy_id: preference.policy_id,
              policy_version: preference.policy_version,
              receipt_digest: Canonical.digest!(projection)
            })
          )

        %{preference: updated, receipt: receipt}
      end
    end)
  end

  @spec suspend(Visitor.t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, Preference.t()} | {:error, term()}
  def suspend(%Visitor{} = owner, preference_id, expected_generation, reason_code) do
    terminal_transition(
      owner,
      preference_id,
      expected_generation,
      "active",
      "suspended",
      reason_code
    )
  end

  @spec delete(Visitor.t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, Preference.t()} | {:error, term()}
  def delete(%Visitor{} = owner, preference_id, expected_generation, reason_code) do
    with {:ok, _reason} <- code(reason_code, :invalid_reason) do
      transaction(fn ->
        with {:ok, preference} <- owned_for_update(owner.id, preference_id),
             :ok <- generation_matches(preference, expected_generation),
             true <-
               preference.status in ~w(candidate reviewed confirmed active suspended) or
                 {:error, :invalid_transition},
             generation <- next_generation!(owner.id) do
          transition!(preference, "deleted", generation,
            terminal_generation: preference.terminal_generation || generation
          )
        end
      end)
    end
  end

  @spec correct(Visitor.t(), Ecto.UUID.t(), pos_integer(), map(), String.t(), String.t()) ::
          {:ok, %{suspended: Preference.t(), candidate: Preference.t()}} | {:error, term()}
  def correct(
        %Visitor{} = owner,
        preference_id,
        expected_generation,
        observation_attributes,
        key,
        value
      )
      when is_map(observation_attributes) do
    with {:ok, prepared} <- prepare_observation(owner, observation_attributes) do
      transaction(fn ->
        with {:ok, old} <- owned_for_update(owner.id, preference_id),
             :ok <- generation_matches(old, expected_generation),
             :ok <- require_status(old, "active"),
             generation <- next_generation!(owner.id),
             suspended <-
               transition!(old, "suspended", generation, terminal_generation: generation),
             observation <- insert!(Observation.changeset(%Observation{}, prepared)),
             candidate <- propose_locked(owner, observation.id, key, value, old.id) do
          %{suspended: suspended, candidate: candidate}
        end
      end)
    end
  end

  @spec capture_snapshot(Visitor.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def capture_snapshot(%Visitor{} = owner) do
    transaction(fn ->
      scope = ensure_scope!(owner.id)
      now = DateTime.utc_now()

      stored =
        insert!(
          SnapshotRecord.changeset(%SnapshotRecord{}, %{
            owner_visitor_id: owner.id,
            scope_generation: scope.generation,
            captured_at: now,
            inserted_at: now
          })
        )

      %Snapshot{
        owner_visitor_id: owner.id,
        generation: scope.generation,
        captured_at: now,
        ref: snapshot_ref(stored.id)
      }
    end)
  end

  def capture_snapshot(_owner), do: {:error, :invalid_owner_scope}

  @spec load_snapshot(Visitor.t(), String.t()) :: {:ok, Snapshot.t()} | {:error, :scope_refused}
  def load_snapshot(%Visitor{id: owner_id}, "preference-snapshot:v1:" <> id) do
    with {:ok, parsed} <- Ecto.UUID.cast(id),
         %SnapshotRecord{} = stored <-
           Repo.get_by(SnapshotRecord, id: parsed, owner_visitor_id: owner_id) do
      {:ok,
       %Snapshot{
         owner_visitor_id: owner_id,
         generation: stored.scope_generation,
         captured_at: stored.captured_at,
         ref: snapshot_ref(stored.id)
       }}
    else
      _invalid -> {:error, :scope_refused}
    end
  end

  def load_snapshot(_owner, _ref), do: {:error, :scope_refused}

  @spec validate_turn_capture(Turn.t(), String.t() | nil, map()) :: :ok | {:error, term()}
  def validate_turn_capture(%Turn{}, nil, usage) do
    if usage == empty_usage(), do: :ok, else: {:error, :invalid_preference_capture}
  end

  def validate_turn_capture(%Turn{} = turn, snapshot_ref, usage) when is_binary(snapshot_ref) do
    owner = OpenAgents.Conversations.get_turn_owner!(turn)
    current_message = Repo.get!(Message, turn.user_message_id)

    with {:ok, snapshot} <- load_snapshot(owner, snapshot_ref),
         {:ok, projection} <- project_active(owner, snapshot, current_message.content),
         true <- projection.usage == usage or {:error, :invalid_preference_capture} do
      :ok
    end
  end

  def validate_turn_capture(_turn, _snapshot_ref, _usage),
    do: {:error, :invalid_preference_capture}

  @spec project_active(Visitor.t(), Snapshot.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def project_active(%Visitor{} = owner, %Snapshot{} = snapshot, current_instruction)
      when is_binary(current_instruction) do
    with :ok <- validate_snapshot(owner, snapshot) do
      preferences = active_at(owner.id, snapshot)

      {applied, overridden} =
        preferences
        |> Enum.map(&project_with_activation!/1)
        |> Enum.split_with(fn projection ->
          not conflicts_with_current?(projection["effect"], current_instruction)
        end)

      usage = %{
        "schema" => "sarah.preference_usage.v1",
        "applied" => Enum.map(applied, &usage_item/1),
        "overridden" =>
          Enum.map(overridden, fn item ->
            item |> usage_item() |> Map.put("reason", "current_instruction")
          end)
      }

      {:ok, %{applied: applied, usage: usage}}
    end
  end

  def project_active(_owner, _snapshot, _current_instruction), do: {:error, :scope_refused}

  @spec inspect_all(Visitor.t()) :: {:ok, [Preference.t()]} | {:error, term()}
  def inspect_all(%Visitor{} = owner) do
    {:ok,
     Repo.all(
       from(preference in Preference,
         where: preference.owner_visitor_id == ^owner.id,
         order_by: [asc: preference.inserted_at, asc: preference.id],
         limit: @maximum_preferences,
         preload: [:observation]
       )
     )}
  end

  @spec record_outcome(Visitor.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, OutcomeReceipt.t()} | {:error, term()}
  def record_outcome(%Visitor{} = owner, preference_id, turn_id, attributes)
      when is_map(attributes) do
    transaction(fn ->
      with %Preference{} = preference <- owned(owner.id, preference_id),
           %Turn{} = turn <- Repo.get(Turn, turn_id),
           :ok <- turn_owned_by(owner.id, turn),
           %TurnReceipt{} = turn_receipt <- Repo.get_by(TurnReceipt, turn_id: turn.id),
           {:ok, activation_ref} <- applied_activation_ref(turn_receipt, preference.id),
           {:ok, activation_id} <- activation_id(activation_ref),
           %ActivationReceipt{} <-
             Repo.get_by(ActivationReceipt,
               id: activation_id,
               preference_id: preference.id,
               owner_visitor_id: owner.id
             ),
           {:ok, outcome} <-
             member(
               attributes["outcome"],
               ~w(benefited neutral corrected rejected),
               :invalid_outcome
             ),
           {:ok, evidence_ref} <- bounded(attributes["evidence_ref"], 256, :invalid_outcome),
           {:ok, reason_code} <- code(attributes["reason_code"], :invalid_outcome) do
        projection = %{
          "preference_id" => preference.id,
          "turn_id" => turn.id,
          "owner_visitor_id" => owner.id,
          "activation_receipt_id" => activation_id,
          "outcome" => outcome,
          "evidence_ref" => evidence_ref,
          "reason_code" => reason_code
        }

        %OutcomeReceipt{}
        |> OutcomeReceipt.changeset(
          Map.put(projection, "receipt_digest", Canonical.digest!(projection))
        )
        |> insert!()
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def record_outcome(_owner, _preference_id, _turn_id, _attributes),
    do: {:error, :invalid_outcome}

  defp prepare_observation(owner, attributes) do
    now = DateTime.utc_now()

    with {:ok, source_kind} <-
           member(
             attributes["source_kind"],
             ~w(current_user_message correction tool_outcome),
             :invalid_observation
           ),
         {:ok, summary} <- bounded(attributes["summary"], 500, :invalid_observation),
         {:ok, confidence} <- confidence(attributes["confidence_millis"]),
         {:ok, proposer_id} <- bounded(attributes["proposer_id"], 128, :invalid_observation),
         {:ok, proposer_digest} <- digest(attributes["proposer_digest"], :invalid_observation),
         :ok <- valid_freshness(now, attributes["freshness_until"]),
         :ok <- validate_source(owner.id, source_kind, attributes["source_message_id"]) do
      evidence = %{
        "owner_visitor_id" => owner.id,
        "source_message_id" => attributes["source_message_id"],
        "source_kind" => source_kind,
        "summary" => summary,
        "observed_at" => DateTime.to_iso8601(now)
      }

      {:ok,
       %{
         owner_visitor_id: owner.id,
         source_message_id: attributes["source_message_id"],
         source_kind: source_kind,
         summary: summary,
         evidence_digest: Canonical.digest!(evidence),
         confidence_millis: confidence,
         observed_at: now,
         freshness_until: attributes["freshness_until"],
         proposer_id: proposer_id,
         proposer_digest: proposer_digest,
         policy_id: @policy_id,
         policy_version: @policy_version
       }}
    end
  end

  defp propose_locked(owner, observation_id, effect_key, effect_value, supersedes_id) do
    with %Observation{} = observation <-
           Repo.get_by(Observation, id: observation_id, owner_visitor_id: owner.id),
         {:ok, value} <- admitted_effect(effect_key, effect_value),
         :ok <- enforce_limit(owner.id),
         generation <- next_generation!(owner.id) do
      effect = %{"key" => effect_key, "value" => value}

      %Preference{}
      |> Preference.create_changeset(%{
        owner_visitor_id: owner.id,
        observation_id: observation.id,
        supersedes_preference_id: supersedes_id,
        category: Map.fetch!(@categories, effect_key),
        effect_key: effect_key,
        effect_value: value,
        proposed_effect: effect,
        effect_digest: Canonical.digest!(effect),
        status: "candidate",
        confidence_millis: observation.confidence_millis,
        freshness_until: observation.freshness_until,
        policy_id: @policy_id,
        policy_version: @policy_version,
        generation: 1,
        created_generation: generation
      })
      |> insert!()
    else
      nil -> Repo.rollback(:observation_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp terminal_transition(owner, preference_id, expected_generation, source, target, reason_code) do
    with {:ok, _reason} <- code(reason_code, :invalid_reason) do
      transaction(fn ->
        with {:ok, preference} <- owned_for_update(owner.id, preference_id),
             :ok <- generation_matches(preference, expected_generation),
             :ok <- require_status(preference, source),
             generation <- next_generation!(owner.id) do
          transition!(preference, target, generation, terminal_generation: generation)
        end
      end)
    end
  end

  defp transition!(preference, status, _scope_generation, options) do
    attributes = %{
      status: status,
      generation: preference.generation + 1,
      active_generation: Keyword.get(options, :active_generation, preference.active_generation),
      terminal_generation:
        Keyword.get(options, :terminal_generation, preference.terminal_generation),
      confirmation_ref: Keyword.get(options, :confirmation_ref, preference.confirmation_ref)
    }

    preference |> Preference.lifecycle_changeset(attributes) |> update!()
  end

  defp active_at(owner_id, snapshot) do
    Repo.all(
      from(preference in Preference,
        where:
          preference.owner_visitor_id == ^owner_id and
            not is_nil(preference.active_generation) and
            preference.active_generation <= ^snapshot.generation and
            (is_nil(preference.terminal_generation) or
               preference.terminal_generation > ^snapshot.generation) and
            (is_nil(preference.freshness_until) or
               preference.freshness_until > ^snapshot.captured_at),
        order_by: [asc: preference.effect_key, asc: preference.id],
        limit: 8
      )
    )
  end

  defp project_with_activation!(preference) do
    receipt =
      Repo.get_by!(ActivationReceipt,
        preference_id: preference.id,
        scope_generation: preference.active_generation
      )

    %{
      "preference_ref" => "preference:v1:#{preference.id}",
      "activation_receipt_ref" => "preference-activation:v1:#{receipt.id}",
      "effect_digest" => preference.effect_digest,
      "effect" => preference.proposed_effect
    }
  end

  defp usage_item(item),
    do: Map.take(item, ~w(preference_ref activation_receipt_ref effect_digest))

  defp conflicts_with_current?(%{"key" => key, "value" => value}, instruction) do
    case current_choice(key, instruction) do
      nil -> false
      ^value -> false
      _different -> true
    end
  end

  defp current_choice("response_length", text) do
    cond do
      Regex.match?(~r/\b(concise|brief|short answer)\b/iu, text) -> "concise"
      Regex.match?(~r/\b(detailed|thorough|in[- ]depth)\b/iu, text) -> "detailed"
      true -> nil
    end
  end

  defp current_choice("format", text) do
    cond do
      Regex.match?(~r/\b(bullets?|bullet points?|list)\b/iu, text) -> "bullets"
      Regex.match?(~r/\b(paragraphs?|prose)\b/iu, text) -> "paragraphs"
      true -> nil
    end
  end

  defp current_choice("tone", text) do
    cond do
      Regex.match?(~r/\b(direct|blunt)\b/iu, text) -> "direct"
      Regex.match?(~r/\b(gentle|softly)\b/iu, text) -> "gentle"
      true -> nil
    end
  end

  defp current_choice("initiative", text) do
    cond do
      Regex.match?(~r/\b(ask|check) (me )?first\b/iu, text) ->
        "ask_first"

      Regex.match?(~r/\b(suggest next steps?|proactive suggestions?)\b/iu, text) ->
        "suggest_next_steps"

      true ->
        nil
    end
  end

  defp validate_confirmation(confirmation, effect_digest) do
    with {:ok, kind} <-
           member(
             confirmation["kind"],
             ~w(exact_confirmation first_party_ui),
             :confirmation_required
           ),
         true <-
           confirmation["effect_digest"] == effect_digest or {:error, :confirmation_mismatch},
         {:ok, ref} <- bounded(confirmation["ref"], 256, :confirmation_required) do
      {:ok, %{kind: kind, ref: ref}}
    end
  end

  defp validate_source(owner_id, source_kind, source_message_id)
       when source_kind in ~w(current_user_message correction) do
    query =
      from(message in Message,
        join: conversation in assoc(message, :conversation),
        where:
          message.id == ^source_message_id and conversation.visitor_id == ^owner_id and
            message.role == "user" and message.status == "complete"
      )

    if is_binary(source_message_id) and Repo.exists?(query),
      do: :ok,
      else: {:error, :invalid_observation_source}
  end

  defp validate_source(_owner_id, "tool_outcome", nil), do: :ok

  defp validate_source(_owner_id, "tool_outcome", source_message_id)
       when is_binary(source_message_id), do: :ok

  defp validate_source(_owner_id, _source_kind, _source_message_id),
    do: {:error, :invalid_observation_source}

  defp validate_snapshot(%Visitor{id: owner_id}, %Snapshot{owner_visitor_id: owner_id}), do: :ok
  defp validate_snapshot(_owner, _snapshot), do: {:error, :scope_refused}

  defp require_no_active_effect(owner_id, effect_key) do
    if Repo.exists?(
         from(p in Preference,
           where:
             p.owner_visitor_id == ^owner_id and p.effect_key == ^effect_key and
               p.status == "active"
         )
       ),
       do: {:error, :active_effect_conflict},
       else: :ok
  end

  defp require_fresh(%Preference{freshness_until: nil}), do: :ok

  defp require_fresh(%Preference{freshness_until: until}),
    do: if(DateTime.after?(until, DateTime.utc_now()), do: :ok, else: {:error, :preference_stale})

  defp ensure_scope!(owner_id) do
    changeset = Scope.changeset(%Scope{}, %{owner_visitor_id: owner_id, generation: 0})

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:owner_visitor_id]
         ) do
      {:ok, _scope_or_placeholder} -> Repo.get!(Scope, owner_id)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp next_generation!(owner_id) do
    _scope = ensure_scope!(owner_id)

    scope =
      Repo.one!(
        from(scope in Scope,
          where: scope.owner_visitor_id == ^owner_id,
          lock: "FOR UPDATE"
        )
      )

    updated = scope |> Scope.changeset(%{generation: scope.generation + 1}) |> update!()
    updated.generation
  end

  defp enforce_limit(owner_id) do
    if Repo.aggregate(from(p in Preference, where: p.owner_visitor_id == ^owner_id), :count) <
         @maximum_preferences,
       do: :ok,
       else: {:error, :preference_limit_reached}
  end

  defp owned(owner_id, id), do: Repo.get_by(Preference, id: id, owner_visitor_id: owner_id)

  defp owned_for_update(owner_id, id) do
    case Repo.one(
           from(p in Preference,
             where: p.id == ^id and p.owner_visitor_id == ^owner_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :not_found}
      preference -> {:ok, preference}
    end
  end

  defp generation_matches(%Preference{generation: generation}, generation), do: :ok
  defp generation_matches(_preference, _expected), do: {:error, :stale_generation}
  defp require_status(%Preference{status: status}, status), do: :ok
  defp require_status(_preference, _status), do: {:error, :invalid_transition}

  defp turn_owned_by(owner_id, %Turn{conversation_id: conversation_id}) do
    if Repo.exists?(
         from(c in OpenAgents.Conversations.Conversation,
           where: c.id == ^conversation_id and c.visitor_id == ^owner_id
         )
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp applied_activation_ref(%TurnReceipt{used_preferences: usage}, preference_id) do
    ref = "preference:v1:#{preference_id}"

    case Enum.find(usage["applied"] || [], &(&1["preference_ref"] == ref)) do
      %{"activation_receipt_ref" => activation_ref} -> {:ok, activation_ref}
      _missing -> {:error, :preference_not_applied}
    end
  end

  defp activation_id("preference-activation:v1:" <> id), do: Ecto.UUID.cast(id)
  defp activation_id(_ref), do: {:error, :invalid_activation_receipt}

  defp admitted_effect(key, value) when is_binary(key) and is_binary(value) do
    if value in Map.get(@effect_values, key, []),
      do: {:ok, value},
      else: {:error, :effect_not_admitted}
  end

  defp admitted_effect(_key, _value), do: {:error, :effect_not_admitted}

  defp confidence(value) when is_integer(value) and value in 0..1000, do: {:ok, value}
  defp confidence(_value), do: {:error, :invalid_confidence}

  defp valid_freshness(_now, nil), do: :ok

  defp valid_freshness(now, %DateTime{} = until),
    do: if(DateTime.after?(until, now), do: :ok, else: {:error, :invalid_freshness})

  defp valid_freshness(_now, _until), do: {:error, :invalid_freshness}

  defp bounded(value, maximum, error) when is_binary(value) do
    normalized = value |> String.replace(~r/\s+/u, " ") |> String.trim()

    if byte_size(normalized) in 1..maximum,
      do: {:ok, normalized},
      else: {:error, error}
  end

  defp bounded(_value, _maximum, error), do: {:error, error}

  defp code(value, error) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, value), do: {:ok, value}, else: {:error, error}
  end

  defp code(_value, error), do: {:error, error}

  defp reviewer(value) when is_binary(value) do
    with {:ok, bounded_value} <- bounded(value, 128, :invalid_reviewer),
         true <-
           String.starts_with?(bounded_value, ["host-policy:", "operator:"]) or
             {:error, :invalid_reviewer} do
      {:ok, bounded_value}
    end
  end

  defp reviewer(_value), do: {:error, :invalid_reviewer}

  defp digest(value, error) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: {:ok, value},
      else: {:error, error}
  end

  defp digest(_value, error), do: {:error, error}

  defp member(value, allowed, error) do
    if value in allowed, do: {:ok, value}, else: {:error, error}
  end

  defp snapshot_ref(id), do: "preference-snapshot:v1:#{id}"

  defp empty_usage,
    do: %{"schema" => "sarah.preference_usage.v1", "applied" => [], "overridden" => []}

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             result -> result
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
