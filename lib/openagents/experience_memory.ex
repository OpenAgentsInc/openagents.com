defmodule OpenAgents.ExperienceMemory do
  @moduledoc "Private, source-linked work outcomes and frozen advisory pattern banks."

  import Ecto.Query

  alias OpenAgents.Collective
  alias OpenAgents.Conversations.{Conversation, Message, ToolStep, Turn, Visitor}

  alias OpenAgents.ExperienceMemory.{
    Bank,
    BankItem,
    DeletionReceipt,
    EvidenceRef,
    Pattern,
    PatternSupport,
    Record,
    Scope
  }

  alias OpenAgents.Memory.Redaction
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy_id "sarah.experience.policy.v1"
  @policy_version 1
  @maximum_records 100
  @maximum_refs 16

  @spec create_case(Visitor.t(), String.t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def create_case(%Visitor{} = owner, work_scope, attributes) when is_map(attributes) do
    with {:ok, prepared} <- prepare_case(owner, work_scope, attributes) do
      transaction(fn ->
        scope = scope_for_update!(owner.id, work_scope)
        enforce_limit!(owner.id, work_scope)
        scope_generation = advance_scope!(scope)
        insert_case!(owner.id, scope, prepared, scope_generation, nil)
      end)
    end
  end

  def create_case(_owner, _work_scope, _attributes), do: {:error, :invalid_experience}

  @spec start_case(Visitor.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Record.t()} | {:error, term()}
  def start_case(%Visitor{} = owner, record_id, expected_generation) do
    transition_case(owner, record_id, expected_generation, "requested", "running", %{})
  end

  @spec complete_case(Visitor.t(), Ecto.UUID.t(), pos_integer(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def complete_case(%Visitor{} = owner, record_id, expected_generation, attributes)
      when is_map(attributes) do
    with {:ok, outcome_state} <-
           member(attributes["outcome_state"], ~w(succeeded failed), :invalid_outcome),
         {:ok, outcome} <- safe_text(attributes["outcome"]),
         {:ok, target_refs} <- bounded_refs(attributes["target_receipt_refs"] || [], "target") do
      transaction(fn ->
        record = owned_for_update!(owner.id, record_id)
        require_generation!(record, expected_generation)
        require_state!(record, "running")

        if outcome_state == "succeeded" do
          if target_refs == [], do: Repo.rollback(:target_receipt_required)
          validate_target_refs!(owner.id, record.work_scope, target_refs)
          insert_refs!(record, "target", target_refs)
        else
          if target_refs != [], do: Repo.rollback(:failed_outcome_cannot_claim_target)
        end

        scope = scope_by_id_for_update!(record.scope_id)
        scope_generation = advance_scope!(scope)

        update!(
          Record.lifecycle_changeset(record, %{
            outcome_state: outcome_state,
            outcome: outcome,
            generation: record.generation + 1,
            scope_generation: scope_generation
          })
        )
      end)
    end
  end

  @spec correct_case(Visitor.t(), Ecto.UUID.t(), pos_integer(), String.t(), map()) ::
          {:ok, %{corrected: Record.t(), replacement: Record.t()}} | {:error, term()}
  def correct_case(%Visitor{} = owner, record_id, expected_generation, correction, replacement)
      when is_map(replacement) do
    with {:ok, correction_text} <- safe_text(correction),
         {:ok, old} <- get(owner, record_id),
         true <- old.outcome_state in ~w(succeeded failed) or {:error, :invalid_transition},
         {:ok, prepared} <- prepare_case(owner, old.work_scope, replacement) do
      transaction(fn ->
        locked = owned_for_update!(owner.id, old.id)
        require_generation!(locked, expected_generation)
        require_terminal!(locked)
        scope = scope_by_id_for_update!(locked.scope_id)
        enforce_limit!(owner.id, old.work_scope)

        corrected_generation = scope.generation + 1
        replacement_generation = scope.generation + 2

        update!(Scope.changeset(scope, %{generation: replacement_generation}))

        corrected =
          update!(
            Record.lifecycle_changeset(locked, %{
              outcome_state: "corrected",
              correction: correction_text,
              generation: locked.generation + 1,
              scope_generation: corrected_generation
            })
          )

        replacement_record =
          insert_case!(
            owner.id,
            scope,
            prepared,
            replacement_generation,
            locked.id
          )

        insert_refs!(corrected, "correction", ["experience:#{replacement_record.id}"])

        %{corrected: corrected, replacement: replacement_record}
      end)
    end
  end

  @spec create_pattern(Visitor.t(), String.t(), map()) :: {:ok, Pattern.t()} | {:error, term()}
  def create_pattern(%Visitor{} = owner, work_scope, attributes) when is_map(attributes) do
    with {:ok, _conversation} <- owned_scope(owner.id, work_scope),
         {:ok, phenomenon} <- safe_text(attributes["phenomenon"]),
         {:ok, applicability} <- safe_text(attributes["applicability"]),
         {:ok, expected_effect} <- safe_text(attributes["expected_effect"]),
         {:ok, confidence} <- confidence(attributes["confidence_millis"]),
         {:ok, support_ids} <- distinct_ids(attributes["support_record_ids"]) do
      transaction(fn ->
        if length(support_ids) < 2, do: Repo.rollback(:insufficient_pattern_support)

        supports =
          Repo.all(
            from(r in Record,
              where:
                r.id in ^support_ids and r.owner_visitor_id == ^owner.id and
                  r.work_scope == ^work_scope and r.outcome_state in ["succeeded", "failed"],
              lock: "FOR UPDATE"
            )
          )

        if length(supports) != length(support_ids), do: Repo.rollback(:invalid_pattern_support)
        scope = scope_for_update!(owner.id, work_scope)
        generation = advance_scope!(scope)

        projection = %{
          "phenomenon" => phenomenon,
          "applicability" => applicability,
          "expected_effect" => expected_effect,
          "supports" =>
            Enum.map(supports, &%{"id" => &1.id, "state" => &1.outcome_state})
            |> Enum.sort_by(& &1["id"])
        }

        pattern =
          insert!(
            Pattern.changeset(%Pattern{}, %{
              owner_visitor_id: owner.id,
              scope_id: scope.id,
              work_scope: work_scope,
              phenomenon: phenomenon,
              applicability: applicability,
              expected_effect: expected_effect,
              confidence_millis: confidence,
              status: "active",
              digest: Canonical.digest!(projection),
              generation: generation
            })
          )

        Enum.each(supports, fn support ->
          insert!(
            PatternSupport.changeset(%PatternSupport{}, %{
              pattern_id: pattern.id,
              record_id: support.id,
              outcome_state: support.outcome_state
            })
          )
        end)

        pattern
      end)
    end
  end

  @spec capture_for_turn(Visitor.t(), Turn.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def capture_for_turn(%Visitor{} = owner, %Turn{} = turn, query) when is_binary(query) do
    config = Application.fetch_env!(:openagents, :experience_memory)

    if Keyword.fetch!(config, :enabled),
      do: freeze_bank(owner, turn, query, config),
      else: {:ok, disabled_capture()}
  end

  def validate_turn_capture(%Turn{}, nil, usage) do
    if usage == empty_usage(), do: :ok, else: {:error, :invalid_experience_capture}
  end

  def validate_turn_capture(%Turn{} = turn, "experience-bank:v1:" <> bank_id, usage) do
    owner = OpenAgents.Conversations.get_turn_owner!(turn)
    work_scope = "conversation:#{turn.conversation_id}"

    with {:ok, id} <- Ecto.UUID.cast(bank_id),
         %Bank{} = bank <-
           Repo.get_by(Bank,
             id: id,
             turn_id: turn.id,
             owner_visitor_id: owner.id,
             work_scope: work_scope,
             status: "frozen"
           ),
         true <- bank_usage(bank) == usage or {:error, :invalid_experience_capture} do
      :ok
    else
      _invalid -> {:error, :invalid_experience_capture}
    end
  end

  def validate_turn_capture(_turn, _ref, _usage), do: {:error, :invalid_experience_capture}

  def inspect(owner, work_scope), do: export_scope(owner, work_scope)

  def export_scope(%Visitor{} = owner, work_scope) do
    with {:ok, _} <- owned_scope(owner.id, work_scope) do
      records =
        Repo.all(
          from(r in Record,
            where: r.owner_visitor_id == ^owner.id and r.work_scope == ^work_scope,
            order_by: [asc: r.inserted_at, asc: r.id],
            limit: @maximum_records
          )
        )

      record_ids = Enum.map(records, & &1.id)

      refs =
        Repo.all(
          from(ref in EvidenceRef,
            where: ref.record_id in ^record_ids,
            order_by: [asc: ref.record_id, asc: ref.kind, asc: ref.reference]
          )
        )
        |> Enum.group_by(& &1.record_id)

      patterns =
        Repo.all(
          from(p in Pattern,
            where: p.owner_visitor_id == ^owner.id and p.work_scope == ^work_scope,
            order_by: [asc: p.inserted_at, asc: p.id],
            limit: 100
          )
        )

      {:ok,
       %{
         "schema" => "sarah.experience_export.v1",
         "scope" => work_scope,
         "records" => Enum.map(records, &export_record(&1, refs[&1.id] || [])),
         "patterns" => Enum.map(patterns, &export_pattern/1),
         "truncated" => length(records) == @maximum_records
       }}
    end
  end

  @spec delete(Visitor.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, DeletionReceipt.t()} | {:error, term()}
  def delete(%Visitor{} = owner, record_id, reason_code) do
    with {:ok, reason} <- code(reason_code) do
      transaction(fn ->
        record = owned_for_update!(owner.id, record_id)
        _scope = scope_by_id_for_update!(record.scope_id)

        source_count =
          Repo.aggregate(from(r in EvidenceRef, where: r.record_id == ^record.id), :count)

        pattern_ids =
          Repo.all(
            from(s in PatternSupport, where: s.record_id == ^record.id, select: s.pattern_id)
          )

        bank_ids =
          Repo.all(
            from(i in BankItem,
              where: i.record_id == ^record.id or i.pattern_id in ^pattern_ids,
              select: i.bank_id
            )
          )
          |> Enum.uniq()

        {bank_items, _} =
          Repo.delete_all(
            from(i in BankItem, where: i.record_id == ^record.id or i.pattern_id in ^pattern_ids)
          )

        {patterns, _} = Repo.delete_all(from(p in Pattern, where: p.id in ^pattern_ids))
        Repo.update_all(from(b in Bank, where: b.id in ^bank_ids), set: [status: "invalidated"])
        Repo.delete!(record)

        projection = %{
          "owner_visitor_id" => owner.id,
          "work_scope" => record.work_scope,
          "record_ref" => "experience:#{record.id}",
          "source_ref_count" => source_count,
          "bank_item_count" => bank_items,
          "pattern_count" => patterns,
          "reason_code" => reason
        }

        insert!(
          DeletionReceipt.changeset(
            %DeletionReceipt{},
            Map.put(projection, "receipt_digest", Canonical.digest!(projection))
          )
        )
      end)
    end
  end

  def propose_collective_candidate(%Visitor{} = owner, record_id, confirmation) do
    with {:ok, record} <- get(owner, record_id),
         true <-
           record.outcome_state in ~w(succeeded failed) or {:error, :experience_not_terminal},
         refs <-
           Repo.all(
             from(r in EvidenceRef,
               where: r.record_id == ^record.id and r.kind == "source",
               select: r.reference
             )
           ),
         true <- refs != [] or {:error, :collective_source_required} do
      Collective.create_candidate(
        owner,
        Map.merge(confirmation, %{"source_scope_ref" => record.work_scope, "source_refs" => refs})
      )
    end
  end

  def get(%Visitor{} = owner, id) do
    case Repo.get_by(Record, id: id, owner_visitor_id: owner.id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp freeze_bank(owner, turn, query, config) do
    work_scope = "conversation:#{turn.conversation_id}"

    with :ok <- owned_turn(owner.id, turn) do
      transaction(fn ->
        scope = scope_for_update!(owner.id, work_scope)

        case bank_for_update(turn.id, owner.id, work_scope) do
          %Bank{status: "frozen"} = bank ->
            capture_from_bank(bank)

          %Bank{status: "invalidated"} ->
            Repo.rollback(:experience_bank_invalidated)

          nil ->
            create_bank!(owner, turn, scope, work_scope, query, config)
        end
      end)
    end
  end

  defp create_bank!(owner, turn, scope, work_scope, query, config) do
    now = DateTime.utc_now()

    records =
      Repo.all(
        from(r in Record,
          where:
            r.owner_visitor_id == ^owner.id and r.work_scope == ^work_scope and
              r.outcome_state in ["succeeded", "failed"] and
              (is_nil(r.retention_until) or r.retention_until > ^now),
          order_by: [asc: r.id],
          limit: 100
        )
      )

    patterns =
      Repo.all(
        from(p in Pattern,
          where:
            p.owner_visitor_id == ^owner.id and p.work_scope == ^work_scope and
              p.status == "active",
          order_by: [asc: p.id],
          limit: 100
        )
      )

    ranked_records =
      records |> Enum.map(&record_projection(&1, query)) |> Enum.sort_by(&{-&1.score, &1.ref})

    ranked_patterns =
      patterns
      |> Enum.map(&pattern_projection(&1, query))
      |> Enum.sort_by(&{-&1.score, &1.ref})

    candidates =
      Enum.take(ranked_patterns, Keyword.fetch!(config, :maximum_patterns)) ++
        Enum.take(ranked_records, Keyword.fetch!(config, :maximum_records))

    {selected, dropped, used} = pack(candidates, Keyword.fetch!(config, :maximum_bytes))
    query_digest = Canonical.sha256(normalize(query))

    digest_projection = %{
      "scope_generation" => scope.generation,
      "query_digest" => query_digest,
      "items" => Enum.map(selected, & &1.projection_digest)
    }

    bank =
      insert!(
        Bank.changeset(%Bank{}, %{
          turn_id: turn.id,
          owner_visitor_id: owner.id,
          scope_id: scope.id,
          work_scope: work_scope,
          scope_generation: scope.generation,
          query_digest: query_digest,
          bank_digest: Canonical.digest!(digest_projection),
          status: "frozen",
          selected_record_refs: for(item <- selected, item.kind == "record", do: item.ref),
          selected_pattern_refs: for(item <- selected, item.kind == "pattern", do: item.ref),
          dropped_refs: Enum.map(dropped, & &1.ref),
          used_bytes: used,
          frozen_at: now,
          inserted_at: now
        })
      )

    Enum.with_index(selected, 1)
    |> Enum.each(fn {item, ordinal} ->
      insert!(
        BankItem.changeset(%BankItem{}, %{
          bank_id: bank.id,
          record_id: item.record_id,
          pattern_id: item.pattern_id,
          kind: item.kind,
          ordinal: ordinal,
          projection: item.projection,
          projection_digest: item.projection_digest
        })
      )
    end)

    capture_from_bank(bank)
  end

  defp bank_for_update(turn_id, owner_id, work_scope),
    do:
      Repo.one(
        from(b in Bank,
          where:
            b.turn_id == ^turn_id and b.owner_visitor_id == ^owner_id and
              b.work_scope == ^work_scope,
          lock: "FOR UPDATE"
        )
      )

  defp capture_from_bank(bank) do
    projections =
      Repo.all(
        from(i in BankItem,
          where: i.bank_id == ^bank.id,
          order_by: [asc: i.ordinal],
          select: i.projection
        )
      )

    %{
      ref: "experience-bank:v1:#{bank.id}",
      projections: projections,
      usage: bank_usage(bank)
    }
  end

  defp record_projection(record, query) do
    refs =
      Repo.all(
        from(r in EvidenceRef,
          where: r.record_id == ^record.id,
          order_by: [asc: r.kind, asc: r.reference]
        )
      )

    target_refs = for ref <- refs, ref.kind == "target", do: ref.reference

    projection = %{
      "experience_ref" => "experience:#{record.id}",
      "state" => record.outcome_state,
      "objective" => clean_bounded!(record.objective, 160),
      "approach" => clean_bounded!(record.approach, 160),
      "outcome" => clean_bounded!(record.outcome, 160),
      "applicability" => clean_bounded!(record.applicability, 160),
      "evidence_refs" => refs |> Enum.map(& &1.reference) |> Enum.take(2),
      "evidence_truncated" => length(refs) > 2,
      "target_receipt_refs" => Enum.take(target_refs, 1),
      "interpretation" =>
        if(record.outcome_state == "succeeded",
          do: "one scoped success with target receipt; advisory, not universal",
          else: "one scoped failure; advisory caution"
        )
    }

    item(
      "record",
      record.id,
      nil,
      projection,
      score(
        query,
        [record.objective, record.applicability, record.approach],
        record.confidence_millis
      )
    )
  end

  defp pattern_projection(pattern, query) do
    counts =
      Repo.all(
        from(s in PatternSupport,
          where: s.pattern_id == ^pattern.id,
          group_by: s.outcome_state,
          select: {s.outcome_state, count(s.record_id)}
        )
      )
      |> Map.new()

    projection = %{
      "pattern_ref" => "experience-pattern:#{pattern.id}",
      "phenomenon" => clean_bounded!(pattern.phenomenon, 400),
      "applicability" => clean_bounded!(pattern.applicability, 400),
      "expected_effect" => clean_bounded!(pattern.expected_effect, 400),
      "support" => %{
        "successes" => Map.get(counts, "succeeded", 0),
        "failures" => Map.get(counts, "failed", 0)
      },
      "interpretation" => "owner-private multi-case pattern; advisory only"
    }

    item(
      "pattern",
      nil,
      pattern.id,
      projection,
      score(query, [pattern.phenomenon, pattern.applicability], pattern.confidence_millis) + 100
    )
  end

  defp item(kind, record_id, pattern_id, projection, score) do
    ref = projection["experience_ref"] || projection["pattern_ref"]

    %{
      kind: kind,
      record_id: record_id,
      pattern_id: pattern_id,
      ref: ref,
      projection: projection,
      projection_digest: Canonical.digest!(projection),
      bytes: byte_size(Jason.encode!(projection)),
      score: score
    }
  end

  defp pack(items, maximum),
    do:
      Enum.reduce(items, {[], [], 0}, fn item, {selected, dropped, used} ->
        if used + item.bytes <= maximum,
          do: {selected ++ [item], dropped, used + item.bytes},
          else: {selected, dropped ++ [item], used}
      end)

  defp score(query, texts, confidence),
    do:
      MapSet.size(MapSet.intersection(terms(query), terms(Enum.join(texts, " ")))) * 1000 +
        confidence

  defp terms(text),
    do: text |> normalize() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true) |> MapSet.new()

  defp normalize(text) when is_binary(text),
    do: text |> String.normalize(:nfkc) |> String.downcase() |> String.trim()

  defp disabled_capture, do: %{ref: nil, projections: [], usage: empty_usage()}

  defp empty_usage,
    do: %{
      "schema" => "sarah.experience_usage.v1",
      "record_refs" => [],
      "pattern_refs" => [],
      "bank_digest" => nil
    }

  defp bank_usage(bank),
    do: %{
      "schema" => "sarah.experience_usage.v1",
      "record_refs" => bank.selected_record_refs,
      "pattern_refs" => bank.selected_pattern_refs,
      "bank_digest" => bank.bank_digest
    }

  defp prepare_case(owner, work_scope, attributes) do
    with {:ok, conversation} <- owned_scope(owner.id, work_scope),
         {:ok, objective} <- safe_text(attributes["objective"]),
         {:ok, approach} <- safe_text(attributes["approach"]),
         {:ok, applicability} <- safe_text(attributes["applicability"]),
         {:ok, confidence_millis} <- confidence(attributes["confidence_millis"]),
         :ok <- valid_retention(attributes["retention_until"]),
         {:ok, source_refs} <- validate_source_refs(conversation, attributes["source_refs"] || []),
         {:ok, trace_refs} <- validate_trace_refs(attributes["trace_refs"] || []) do
      {:ok,
       %{
         work_scope: work_scope,
         objective: objective,
         approach: approach,
         applicability: applicability,
         confidence_millis: confidence_millis,
         retention_until: attributes["retention_until"],
         source_refs: source_refs,
         trace_refs: trace_refs
       }}
    end
  end

  defp insert_case!(owner_id, scope, prepared, scope_generation, supersedes_record_id) do
    projection = %{
      "owner_visitor_id" => owner_id,
      "work_scope" => prepared.work_scope,
      "objective" => prepared.objective,
      "approach" => prepared.approach,
      "applicability" => prepared.applicability,
      "source_refs" => prepared.source_refs,
      "trace_refs" => prepared.trace_refs,
      "supersedes_record_id" => supersedes_record_id
    }

    record =
      insert!(
        Record.create_changeset(%Record{}, %{
          owner_visitor_id: owner_id,
          scope_id: scope.id,
          supersedes_record_id: supersedes_record_id,
          work_scope: prepared.work_scope,
          objective: prepared.objective,
          approach: prepared.approach,
          outcome_state: "requested",
          applicability: prepared.applicability,
          confidence_millis: prepared.confidence_millis,
          retention_until: prepared.retention_until,
          policy_id: @policy_id,
          policy_version: @policy_version,
          content_digest: Canonical.digest!(projection),
          generation: 1,
          scope_generation: scope_generation
        })
      )

    insert_refs!(record, "source", prepared.source_refs)
    insert_refs!(record, "trace", prepared.trace_refs)
    record
  end

  defp transition_case(owner, id, expected, source, target, attrs) do
    transaction(fn ->
      record = owned_for_update!(owner.id, id)
      require_generation!(record, expected)
      require_state!(record, source)
      scope = scope_by_id_for_update!(record.scope_id)
      generation = advance_scope!(scope)

      update!(
        Record.lifecycle_changeset(
          record,
          Map.merge(attrs, %{
            outcome_state: target,
            generation: record.generation + 1,
            scope_generation: generation
          })
        )
      )
    end)
  end

  defp scope_for_update!(owner_id, work_scope) do
    changeset =
      Scope.changeset(%Scope{}, %{
        owner_visitor_id: owner_id,
        work_scope: work_scope,
        generation: 0
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:owner_visitor_id, :work_scope]
         ) do
      {:ok, _scope} ->
        Repo.one!(
          from(s in Scope,
            where: s.owner_visitor_id == ^owner_id and s.work_scope == ^work_scope,
            lock: "FOR UPDATE"
          )
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp scope_by_id_for_update!(scope_id),
    do: Repo.one!(from(s in Scope, where: s.id == ^scope_id, lock: "FOR UPDATE"))

  defp advance_scope!(scope),
    do: (scope |> Scope.changeset(%{generation: scope.generation + 1}) |> update!()).generation

  defp owned_for_update!(owner_id, id),
    do:
      Repo.one(
        from(r in Record,
          where: r.id == ^id and r.owner_visitor_id == ^owner_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

  defp require_generation!(%Record{generation: expected}, expected), do: :ok
  defp require_generation!(_, _), do: Repo.rollback(:stale_generation)
  defp require_state!(%Record{outcome_state: state}, state), do: :ok
  defp require_state!(_, _), do: Repo.rollback(:invalid_transition)

  defp require_terminal!(%Record{outcome_state: state}) when state in ~w(succeeded failed),
    do: :ok

  defp require_terminal!(_), do: Repo.rollback(:invalid_transition)

  defp enforce_limit!(owner_id, scope),
    do:
      if(
        Repo.aggregate(
          from(r in Record, where: r.owner_visitor_id == ^owner_id and r.work_scope == ^scope),
          :count
        ) >= @maximum_records,
        do: Repo.rollback(:experience_limit_reached),
        else: :ok
      )

  defp owned_scope(owner_id, "conversation:" <> id) do
    with {:ok, parsed} <- Ecto.UUID.cast(id),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, id: parsed, visitor_id: owner_id) do
      {:ok, conversation}
    else
      _invalid -> {:error, :scope_refused}
    end
  end

  defp owned_scope(_, _), do: {:error, :scope_refused}

  defp owned_turn(owner_id, %Turn{} = turn) do
    if Repo.exists?(
         from(t in Turn,
           join: c in Conversation,
           on: c.id == t.conversation_id,
           where:
             t.id == ^turn.id and t.conversation_id == ^turn.conversation_id and
               c.visitor_id == ^owner_id
         )
       ),
       do: :ok,
       else: {:error, :scope_refused}
  end

  defp validate_source_refs(conversation, refs) do
    with {:ok, values} <- bounded_refs(refs, "source") do
      valid =
        Enum.all?(values, fn
          "message:" <> id ->
            match?({:ok, _}, Ecto.UUID.cast(id)) and
              Repo.exists?(
                from(m in Message,
                  where:
                    m.id == ^id and m.conversation_id == ^conversation.id and
                      m.status == "complete"
                )
              )

          "tool-step:" <> id ->
            match?({:ok, _}, Ecto.UUID.cast(id)) and
              Repo.exists?(
                from(s in ToolStep,
                  join: t in Turn,
                  on: t.id == s.turn_id,
                  where: s.id == ^id and t.conversation_id == ^conversation.id
                )
              )

          _ ->
            false
        end)

      if valid, do: {:ok, values}, else: {:error, :invalid_source_ref}
    end
  end

  defp validate_trace_refs(refs) do
    with {:ok, values} <- bounded_refs(refs, "trace"),
         true <-
           Enum.all?(values, &Regex.match?(~r/\Atrace:v1:[0-9a-f]{64}\z/, &1)) or
             {:error, :invalid_trace_ref} do
      {:ok, values}
    end
  end

  defp bounded_refs(refs, _kind) when is_list(refs) and length(refs) <= @maximum_refs do
    values = Enum.uniq(refs)

    if length(values) == length(refs) and
         Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..256)),
       do: {:ok, Enum.sort(values)},
       else: {:error, :invalid_refs}
  end

  defp bounded_refs(_, _), do: {:error, :invalid_refs}

  defp validate_target_refs!(owner_id, "conversation:" <> conversation_id, refs) do
    Enum.each(refs, fn ref ->
      found =
        Repo.exists?(
          from(s in ToolStep,
            join: t in Turn,
            on: t.id == s.turn_id,
            join: c in Conversation,
            on: c.id == t.conversation_id,
            where:
              c.id == ^conversation_id and c.visitor_id == ^owner_id and s.status == "succeeded" and
                fragment("? = ANY(?)", ^ref, s.target_receipt_refs)
          )
        )

      if not found, do: Repo.rollback(:target_receipt_not_found)
    end)
  end

  defp insert_refs!(record, kind, refs),
    do:
      Enum.each(refs, fn ref ->
        insert!(
          EvidenceRef.changeset(%EvidenceRef{}, %{
            record_id: record.id,
            owner_visitor_id: record.owner_visitor_id,
            work_scope: record.work_scope,
            kind: kind,
            reference: ref,
            reference_digest: Canonical.sha256(ref)
          })
        )
      end)

  defp safe_text(value) when is_binary(value) do
    normalized = value |> String.replace(~r/\s+/u, " ") |> String.trim()

    cond do
      byte_size(normalized) not in 1..1000 -> {:error, :invalid_experience_text}
      Redaction.classify(normalized) != :safe -> {:error, :unsafe_experience_text}
      true -> {:ok, normalized}
    end
  end

  defp safe_text(_), do: {:error, :invalid_experience_text}
  defp clean!(nil), do: ""

  defp clean!(text) do
    case Redaction.project(text) do
      {:ok, clean} -> clean
      {:withheld, _} -> "[withheld]"
    end
  end

  defp clean_bounded!(text, maximum_graphemes),
    do: text |> clean!() |> String.slice(0, maximum_graphemes)

  defp confidence(v) when is_integer(v) and v in 0..1000, do: {:ok, v}
  defp confidence(_), do: {:error, :invalid_confidence}
  defp valid_retention(nil), do: :ok

  defp valid_retention(%DateTime{} = at),
    do: if(DateTime.after?(at, DateTime.utc_now()), do: :ok, else: {:error, :invalid_retention})

  defp valid_retention(_), do: {:error, :invalid_retention}

  defp distinct_ids(ids) when is_list(ids) and length(ids) <= 20,
    do:
      if(
        length(Enum.uniq(ids)) == length(ids) and
          Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
        do: {:ok, ids},
        else: {:error, :invalid_support_refs}
      )

  defp distinct_ids(_), do: {:error, :invalid_support_refs}

  defp member(value, allowed, error),
    do: if(value in allowed, do: {:ok, value}, else: {:error, error})

  defp code(value) when is_binary(value),
    do:
      if(Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, value),
        do: {:ok, value},
        else: {:error, :invalid_reason}
      )

  defp code(_), do: {:error, :invalid_reason}

  defp export_record(record, refs),
    do: %{
      "record_ref" => "experience:#{record.id}",
      "work_scope" => record.work_scope,
      "objective" => record.objective,
      "approach" => record.approach,
      "state" => record.outcome_state,
      "outcome" => record.outcome,
      "correction" => record.correction,
      "applicability" => record.applicability,
      "evidence_refs" => Enum.map(refs, &%{"kind" => &1.kind, "ref" => &1.reference}),
      "generation" => record.generation
    }

  defp export_pattern(pattern),
    do: %{
      "pattern_ref" => "experience-pattern:#{pattern.id}",
      "phenomenon" => pattern.phenomenon,
      "applicability" => pattern.applicability,
      "expected_effect" => pattern.expected_effect,
      "status" => pattern.status
    }

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             value -> value
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
