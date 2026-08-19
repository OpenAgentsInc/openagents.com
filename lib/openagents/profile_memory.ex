defmodule OpenAgents.ProfileMemory do
  @moduledoc """
  Governed durable profile claims confined to one authenticated account owner scope.

  Conversation history never enters this plane without an explicit candidate
  creation call. Activation additionally requires a same-owner source or a
  recorded explicit owner assertion.
  """

  import Ecto.Query

  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.Memory.{Policy, Redaction}
  alias OpenAgents.ProfileMemory.{Record, Scope, Snapshot, SnapshotRecord, Source}
  alias OpenAgents.Repo

  @topic_prefix "profile-memory:"

  @maximum_claim_bytes 500
  @maximum_records_per_owner 200
  @maximum_sources 8
  @singleton_categories ~w(name role)
  @active_category_limits %{
    "name" => 1,
    "role" => 1,
    "project" => 25,
    "preference" => 50,
    "constraint" => 25,
    "other" => 25
  }
  @terminal_statuses ~w(superseded forgotten expired)
  @transitions %{
    "candidate" => ~w(active forgotten expired),
    "active" => ~w(superseded forgotten expired),
    "superseded" => [],
    "forgotten" => [],
    "expired" => []
  }

  @type reason :: atom() | tuple() | Ecto.Changeset.t()

  @spec create_candidate(Visitor.t(), map()) :: {:ok, Record.t()} | {:error, reason()}
  def create_candidate(%Visitor{} = owner, attributes) when is_map(attributes) do
    with {:ok, prepared} <- prepare_attributes(owner, attributes) do
      transaction(fn -> create_candidate_in_transaction(owner, prepared) end)
    end
  end

  def create_candidate(_owner, _attributes), do: {:error, :invalid_owner_scope}

  @spec remember_explicit(Visitor.t(), map()) ::
          {:ok, %{disposition: String.t(), record: Record.t()}} | {:error, reason()}
  def remember_explicit(%Visitor{} = owner, attributes) when is_map(attributes) do
    result =
      with {:ok, prepared} <- prepare_attributes(owner, attributes) do
        transaction(fn ->
          case active_record(owner.id, prepared.category, prepared.claim) do
            %Record{} = record ->
              %{disposition: "already_active", record: Repo.preload(record, :sources)}

            nil ->
              with %Record{} = candidate <- create_candidate_in_transaction(owner, prepared),
                   {:ok, scope_generation} <- next_scope_generation(owner.id),
                   :ok <- validate_activation(owner.id, candidate, "active"),
                   {:ok, active} <- apply_transition(candidate, "active", scope_generation) do
                %{disposition: "stored", record: Repo.preload(active, :sources)}
              end
          end
        end)
      end

    broadcast_result(owner, result)
  end

  def remember_explicit(_owner, _attributes), do: {:error, :invalid_owner_scope}

  @spec forget_active(Visitor.t(), map()) ::
          {:ok, %{disposition: String.t(), records: [Record.t()]}} | {:error, reason()}
  def forget_active(%Visitor{} = owner, selector) when is_map(selector) do
    result =
      transaction(fn ->
        with {:ok, records} <- active_records_for_forget(owner.id, selector),
             :ok <- validate_forget_generation(records, selector) do
          case records do
            [] ->
              %{disposition: "already_absent", records: []}

            active ->
              with {:ok, scope_generation} <- next_scope_generation(owner.id),
                   {:ok, forgotten} <- forget_records(active, scope_generation) do
                %{disposition: "forgotten", records: Repo.preload(forgotten, :sources)}
              end
          end
        end
      end)

    broadcast_result(owner, result)
  end

  def forget_active(_owner, _selector), do: {:error, :invalid_owner_scope}

  @spec transition(Visitor.t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, Record.t()} | {:error, reason()}
  def transition(%Visitor{} = owner, record_id, expected_generation, target_status)
      when is_binary(record_id) and is_integer(expected_generation) do
    transaction(fn ->
      with {:ok, record} <- owned_record_for_update(owner.id, record_id),
           :ok <- generation_matches(record, expected_generation),
           :ok <- valid_transition(record.status, target_status),
           {:ok, scope_generation} <- next_scope_generation(owner.id),
           :ok <- validate_activation(owner.id, record, target_status),
           {:ok, updated} <- apply_transition(record, target_status, scope_generation) do
        updated
      end
    end)
  end

  def transition(_owner, _record_id, _expected_generation, _target_status),
    do: {:error, :invalid_transition_request}

  @spec correct(Visitor.t(), Ecto.UUID.t(), pos_integer(), map()) ::
          {:ok, %{superseded: Record.t(), replacement: Record.t()}} | {:error, reason()}
  def correct(%Visitor{} = owner, record_id, expected_generation, attributes)
      when is_binary(record_id) and is_integer(expected_generation) and is_map(attributes) do
    result =
      with {:ok, prepared} <- prepare_attributes(owner, attributes) do
        transaction(fn ->
          with {:ok, old_record} <- owned_record_for_update(owner.id, record_id),
               :ok <- generation_matches(old_record, expected_generation),
               :ok <- require_active(old_record),
               :ok <- ensure_replacement_differs(old_record, prepared),
               :ok <- validate_prepared_support(owner.id, prepared),
               {:ok, scope_generation} <- next_scope_generation(owner.id),
               :ok <- enforce_record_limit(owner.id),
               {:ok, superseded} <-
                 apply_transition(old_record, "superseded", scope_generation),
               {:ok, replacement} <-
                 insert_record(owner, prepared, scope_generation,
                   status: "active",
                   active_generation: scope_generation,
                   supersedes_record_id: old_record.id
                 ) do
            %{superseded: superseded, replacement: replacement}
          end
        end)
      end

    broadcast_result(owner, result)
  end

  def correct(_owner, _record_id, _expected_generation, _attributes),
    do: {:error, :invalid_correction_request}

  @spec capture_snapshot(Visitor.t()) :: {:ok, Snapshot.t()} | {:error, reason()}
  def capture_snapshot(%Visitor{} = owner) do
    with {:ok, scope} <- ensure_scope(owner.id),
         captured_at = DateTime.utc_now(),
         {:ok, stored} <-
           Repo.insert(
             SnapshotRecord.changeset(%SnapshotRecord{}, %{
               owner_visitor_id: owner.id,
               scope_generation: scope.generation,
               captured_at: captured_at,
               inserted_at: captured_at
             })
           ) do
      {:ok,
       %Snapshot{
         owner_visitor_id: owner.id,
         generation: scope.generation,
         captured_at: captured_at,
         ref: snapshot_ref(stored.id)
       }}
    end
  end

  def capture_snapshot(_owner), do: {:error, :invalid_owner_scope}

  @spec load_snapshot(Visitor.t(), String.t()) :: {:ok, Snapshot.t()} | {:error, :scope_refused}
  def load_snapshot(%Visitor{id: owner_id}, "profile-memory-snapshot:v1:" <> snapshot_id) do
    with {:ok, parsed_id} <- Ecto.UUID.cast(snapshot_id),
         %SnapshotRecord{} = stored <-
           Repo.one(
             from(snapshot in SnapshotRecord,
               where: snapshot.id == ^parsed_id and snapshot.owner_visitor_id == ^owner_id
             )
           ) do
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

  @spec list_active(Visitor.t(), Snapshot.t(), keyword()) ::
          {:ok, [Record.t()]} | {:error, reason()}
  def list_active(owner, snapshot, options \\ [])

  def list_active(%Visitor{} = owner, %Snapshot{} = snapshot, options) do
    with :ok <- validate_snapshot(owner, snapshot),
         {:ok, limit} <- bounded_limit(options, 100) do
      records =
        Repo.all(
          from(record in Record,
            where:
              record.owner_visitor_id == ^owner.id and
                not is_nil(record.active_generation) and
                record.active_generation <= ^snapshot.generation and
                (is_nil(record.terminal_generation) or
                   record.terminal_generation > ^snapshot.generation) and
                (is_nil(record.valid_from) or record.valid_from <= ^snapshot.captured_at) and
                (is_nil(record.valid_until) or record.valid_until > ^snapshot.captured_at) and
                (is_nil(record.expires_at) or record.expires_at > ^snapshot.captured_at),
            order_by: [asc: record.category, asc: record.claim, asc: record.id],
            limit: ^limit,
            preload: [sources: :message]
          )
        )
        |> Enum.map(&%{&1 | status: "active"})

      {:ok, records}
    end
  end

  def list_active(_owner, _snapshot, _options), do: {:error, :scope_refused}

  @spec list_current(Visitor.t(), keyword()) :: {:ok, [Record.t()]} | {:error, reason()}
  def list_current(%Visitor{} = owner, options \\ []) do
    with {:ok, snapshot} <- capture_snapshot(owner) do
      list_active(owner, snapshot, options)
    end
  end

  @spec project_active(Visitor.t(), Snapshot.t(), keyword()) ::
          {:ok, [map()]} | {:error, reason()}
  def project_active(owner, snapshot, options \\ [])

  def project_active(%Visitor{} = owner, %Snapshot{} = snapshot, options) do
    with {:ok, records} <- list_active(owner, snapshot, options) do
      {:ok, Enum.map(records, &export_record/1)}
    end
  end

  def project_active(_owner, _snapshot, _options), do: {:error, :scope_refused}

  @spec get(Visitor.t(), Ecto.UUID.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def get(%Visitor{id: owner_id}, record_id) when is_binary(record_id) do
    case Repo.one(
           from(record in Record,
             where: record.owner_visitor_id == ^owner_id and record.id == ^record_id,
             preload: [:sources]
           )
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  def get(_owner, _record_id), do: {:error, :not_found}

  @spec export(Visitor.t()) :: {:ok, map()} | {:error, reason()}
  def export(%Visitor{} = owner) do
    records =
      Repo.all(
        from(record in Record,
          where: record.owner_visitor_id == ^owner.id,
          order_by: [asc: record.inserted_at, asc: record.id],
          limit: @maximum_records_per_owner,
          preload: [sources: :message]
        )
      )

    {:ok,
     %{
       "schema" => "sarah.profile_memory_export.v1",
       "scope" => "this_browser",
       "records" => Enum.map(records, &export_record/1),
       "truncated" => length(records) == @maximum_records_per_owner
     }}
  end

  def export(_owner), do: {:error, :invalid_owner_scope}

  @spec purge(Visitor.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, :purged} | {:error, reason()}
  def purge(%Visitor{} = owner, record_id, expected_generation)
      when is_binary(record_id) and is_integer(expected_generation) do
    transaction(fn ->
      with {:ok, record} <- owned_record_for_update(owner.id, record_id),
           :ok <- generation_matches(record, expected_generation),
           :ok <- require_terminal(record),
           {:ok, _deleted} <- Repo.delete(record) do
        :purged
      end
    end)
  end

  def purge(_owner, _record_id, _expected_generation), do: {:error, :invalid_purge_request}

  @spec expire_due(Visitor.t(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, reason()}
  def expire_due(%Visitor{} = owner, %DateTime{} = now) do
    transaction(fn ->
      due =
        Repo.all(
          from(record in Record,
            where:
              record.owner_visitor_id == ^owner.id and record.status == "active" and
                not is_nil(record.expires_at) and record.expires_at <= ^now,
            lock: "FOR UPDATE"
          )
        )

      case due do
        [] ->
          0

        records ->
          with {:ok, scope_generation} <- next_scope_generation(owner.id) do
            Enum.each(records, fn record ->
              case apply_transition(record, "expired", scope_generation) do
                {:ok, _expired} -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end
            end)

            length(records)
          end
      end
    end)
  end

  def expire_due(_owner, _now), do: {:error, :invalid_expiry_request}

  @spec transitions() :: map()
  def transitions, do: @transitions

  def subscribe(%Visitor{id: owner_id}) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @topic_prefix <> owner_id)
  end

  defp create_candidate_in_transaction(owner, prepared) do
    with {:ok, scope_generation} <- next_scope_generation(owner.id),
         :ok <- enforce_record_limit(owner.id),
         :ok <- validate_prepared_sources(owner.id, prepared.sources),
         {:ok, record} <- insert_record(owner, prepared, scope_generation, status: "candidate") do
      record
    end
  end

  defp insert_record(owner, prepared, scope_generation, options) do
    status = Keyword.fetch!(options, :status)

    attributes = %{
      owner_visitor_id: owner.id,
      schema_version: 1,
      category: prepared.category,
      claim: prepared.claim,
      claim_fingerprint: fingerprint(prepared.category, prepared.claim),
      status: status,
      provenance: prepared.provenance,
      confidence: prepared.confidence,
      valid_from: prepared.valid_from,
      valid_until: prepared.valid_until,
      confirmed_at: prepared.confirmed_at,
      expires_at: prepared.expires_at,
      owner_asserted_at: prepared.owner_asserted_at,
      redaction_policy: prepared.redaction_policy,
      policy_version: prepared.policy_version,
      creator: prepared.creator,
      creator_artifact_id: prepared.creator_artifact_id,
      creator_artifact_digest: prepared.creator_artifact_digest,
      generation: 1,
      created_generation: scope_generation,
      active_generation: Keyword.get(options, :active_generation),
      terminal_generation: nil,
      supersedes_record_id: Keyword.get(options, :supersedes_record_id)
    }

    with {:ok, record} <- Repo.insert(Record.create_changeset(%Record{}, attributes)),
         :ok <- insert_sources(record, prepared.sources) do
      {:ok, Repo.preload(record, :sources)}
    end
  end

  defp insert_sources(record, sources) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      attributes = %{
        memory_record_id: record.id,
        message_id: source.message_id,
        source_kind: source.kind,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Source.changeset(%Source{}, attributes)) do
        {:ok, _source} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp prepare_attributes(owner, attributes) do
    category = value(attributes, :category)
    creator = value(attributes, :creator)
    raw_claim = value(attributes, :claim)

    with true <- category in Record.categories(),
         true <- is_binary(raw_claim),
         :ok <- Policy.admit_candidate(owner, category, raw_claim),
         {:ok, claim} <- normalize_claim(raw_claim),
         true <- creator in Record.creators(),
         {:ok, provenance} <- validate_provenance(value(attributes, :provenance, %{})),
         {:ok, sources} <- prepare_sources(value(attributes, :sources, [])),
         :ok <- validate_prepared_sources(owner.id, sources),
         :ok <- admit_source_content(owner, category, sources),
         :ok <-
           Policy.admit_metadata(owner, category, %{
             provenance: provenance,
             creator_artifact_id: value(attributes, :creator_artifact_id),
             creator_artifact_digest: value(attributes, :creator_artifact_digest)
           }),
         {:ok, owner_asserted_at} <- owner_assertion(attributes, creator),
         :ok <- validate_model_provenance(attributes, creator, provenance),
         :ok <- validate_times(attributes) do
      {:ok,
       %{
         category: category,
         claim: claim,
         creator: creator,
         provenance: provenance,
         sources: sources,
         owner_asserted_at: owner_asserted_at,
         confidence:
           value(attributes, :confidence, if(creator == "user_explicit", do: 1, else: 0.5)),
         valid_from: value(attributes, :valid_from),
         valid_until: value(attributes, :valid_until),
         confirmed_at: value(attributes, :confirmed_at),
         expires_at: value(attributes, :expires_at),
         redaction_policy: Redaction.version(),
         policy_version: Policy.version(),
         creator_artifact_id: value(attributes, :creator_artifact_id),
         creator_artifact_digest: value(attributes, :creator_artifact_digest)
       }}
    else
      false -> {:error, :invalid_memory_attributes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_claim(claim) when is_binary(claim) do
    normalized = claim |> String.replace(~r/\s+/u, " ") |> String.trim()

    if byte_size(normalized) in 1..@maximum_claim_bytes,
      do: {:ok, normalized},
      else: {:error, :invalid_claim}
  end

  defp validate_provenance(provenance) when is_map(provenance) do
    case Jason.encode(provenance) do
      {:ok, encoded} when byte_size(encoded) <= 4_096 -> {:ok, provenance}
      _invalid -> {:error, :invalid_provenance}
    end
  end

  defp validate_provenance(_provenance), do: {:error, :invalid_provenance}

  defp prepare_sources(sources) when is_list(sources) and length(sources) <= @maximum_sources do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, prepared} ->
      source_ref = value(source, :source_ref)
      kind = value(source, :kind)

      with "message:" <> message_id <- source_ref,
           {:ok, parsed_id} <- Ecto.UUID.cast(message_id),
           true <- kind in ["owner_statement", "owner_confirmation"] do
        {:cont, {:ok, [%{message_id: parsed_id, kind: kind} | prepared]}}
      else
        _invalid -> {:halt, {:error, :invalid_source}}
      end
    end)
    |> case do
      {:ok, prepared} ->
        deduplicated = Enum.uniq_by(prepared, & &1.message_id)

        if length(deduplicated) == length(prepared),
          do: {:ok, Enum.reverse(prepared)},
          else: {:error, :duplicate_source}

      error ->
        error
    end
  end

  defp prepare_sources(_sources), do: {:error, :invalid_sources}

  defp owner_assertion(attributes, "user_explicit") do
    if value(attributes, :owner_asserted, false), do: {:ok, DateTime.utc_now()}, else: {:ok, nil}
  end

  defp owner_assertion(attributes, _creator) do
    if value(attributes, :owner_asserted, false),
      do: {:error, :invalid_owner_assertion},
      else: {:ok, nil}
  end

  defp validate_model_provenance(attributes, "model_proposal", provenance) do
    artifact_id = value(attributes, :creator_artifact_id)
    artifact_digest = value(attributes, :creator_artifact_digest)

    if is_binary(artifact_id) and artifact_id != "" and
         is_binary(artifact_digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact_digest) and
         is_binary(provenance["model_id"]) and provenance["model_id"] != "" do
      :ok
    else
      {:error, :missing_model_provenance}
    end
  end

  defp validate_model_provenance(attributes, _creator, _provenance) do
    artifact_id = value(attributes, :creator_artifact_id)
    artifact_digest = value(attributes, :creator_artifact_digest)

    if (is_nil(artifact_id) and is_nil(artifact_digest)) or
         (is_binary(artifact_id) and artifact_id != "" and is_binary(artifact_digest) and
            Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact_digest)) do
      :ok
    else
      {:error, :invalid_artifact_provenance}
    end
  end

  defp validate_times(attributes) do
    valid_from = value(attributes, :valid_from)
    valid_until = value(attributes, :valid_until)
    confirmed_at = value(attributes, :confirmed_at)
    expires_at = value(attributes, :expires_at)
    times = [valid_from, valid_until, confirmed_at, expires_at]

    cond do
      not Enum.all?(times, &(is_nil(&1) or match?(%DateTime{}, &1))) ->
        {:error, :invalid_memory_time}

      valid_from && valid_until && DateTime.compare(valid_until, valid_from) != :gt ->
        {:error, :invalid_memory_time}

      valid_from && expires_at && DateTime.compare(expires_at, valid_from) != :gt ->
        {:error, :invalid_memory_time}

      true ->
        :ok
    end
  end

  defp validate_prepared_support(owner_id, prepared) do
    if prepared.owner_asserted_at || prepared.sources != [],
      do: validate_prepared_sources(owner_id, prepared.sources),
      else: {:error, :active_memory_requires_support}
  end

  defp validate_prepared_sources(_owner_id, []), do: :ok

  defp validate_prepared_sources(owner_id, sources) do
    message_ids = Enum.map(sources, & &1.message_id)

    count =
      Repo.aggregate(
        from(message in Message,
          join: conversation in assoc(message, :conversation),
          where:
            message.id in ^message_ids and conversation.visitor_id == ^owner_id and
              message.role == "user" and message.status == "complete"
        ),
        :count
      )

    if count == length(message_ids), do: :ok, else: {:error, :invalid_source}
  end

  defp admit_source_content(_owner, _category, []), do: :ok

  defp admit_source_content(owner, category, sources) do
    message_ids = Enum.map(sources, & &1.message_id)

    from(message in Message,
      where:
        message.id in ^message_ids and
          message.conversation_id in subquery(
            from(conversation in OpenAgents.Conversations.Conversation,
              where: conversation.visitor_id == ^owner.id,
              select: conversation.id
            )
          ),
      select: message.content
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn content, :ok ->
      case Policy.admit_candidate(owner, category, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_activation(_owner_id, _record, target_status) when target_status != "active",
    do: :ok

  defp validate_activation(owner_id, record, "active") do
    now = DateTime.utc_now()

    with false <- expired_at?(record.valid_until, now) or expired_at?(record.expires_at, now),
         true <- not is_nil(record.owner_asserted_at) or source_count(record.id, owner_id) > 0,
         :ok <- check_activation_conflicts(record) do
      :ok
    else
      true -> {:error, :memory_already_expired}
      false -> {:error, :active_memory_requires_support}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expired_at?(nil, _now), do: false
  defp expired_at?(%DateTime{} = time, now), do: DateTime.compare(time, now) != :gt

  defp check_activation_conflicts(record) do
    active =
      Repo.one(
        from(other in Record,
          where:
            other.owner_visitor_id == ^record.owner_visitor_id and other.status == "active" and
              other.id != ^record.id and
              (other.claim_fingerprint == ^record.claim_fingerprint or
                 (^record.category in @singleton_categories and other.category == ^record.category)),
          limit: 1
        )
      )

    cond do
      is_nil(active) -> enforce_active_category_limit(record)
      active.claim_fingerprint == record.claim_fingerprint -> {:error, :duplicate_memory}
      true -> {:error, :memory_conflict_requires_correction}
    end
  end

  defp enforce_active_category_limit(record) do
    count =
      Repo.aggregate(
        from(other in Record,
          where:
            other.owner_visitor_id == ^record.owner_visitor_id and
              other.category == ^record.category and other.status == "active"
        ),
        :count
      )

    if count < Map.fetch!(@active_category_limits, record.category),
      do: :ok,
      else: {:error, :memory_category_limit_reached}
  end

  defp source_count(record_id, owner_id) do
    Repo.aggregate(
      from(source in Source,
        join: message in Message,
        on: message.id == source.message_id,
        join: conversation in assoc(message, :conversation),
        where:
          source.memory_record_id == ^record_id and conversation.visitor_id == ^owner_id and
            message.role == "user" and message.status == "complete"
      ),
      :count
    )
  end

  defp apply_transition(record, target_status, scope_generation) do
    attributes =
      case target_status do
        "active" ->
          %{status: "active", active_generation: scope_generation, terminal_generation: nil}

        terminal when terminal in @terminal_statuses ->
          %{status: terminal, terminal_generation: scope_generation}
      end

    Repo.update(Record.transition_changeset(record, attributes))
  end

  defp ensure_scope(owner_id) do
    changeset = Scope.changeset(%Scope{}, %{owner_visitor_id: owner_id, generation: 0})

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:owner_visitor_id]) do
      {:ok, _scope} ->
        case Repo.get(Scope, owner_id) do
          nil -> {:error, :unknown_owner_scope}
          scope -> {:ok, scope}
        end

      {:error, _changeset} ->
        {:error, :unknown_owner_scope}
    end
  end

  defp next_scope_generation(owner_id) do
    with {:ok, _scope} <- ensure_scope(owner_id),
         %Scope{} = locked <-
           Repo.one(
             from(scope in Scope, where: scope.owner_visitor_id == ^owner_id, lock: "FOR UPDATE")
           ),
         {:ok, updated} <-
           Repo.update(Scope.changeset(locked, %{generation: locked.generation + 1})) do
      {:ok, updated.generation}
    else
      nil -> {:error, :unknown_owner_scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp owned_record_for_update(owner_id, record_id) do
    case Repo.one(
           from(record in Record,
             where: record.owner_visitor_id == ^owner_id and record.id == ^record_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp generation_matches(%Record{generation: generation}, generation), do: :ok
  defp generation_matches(_record, _expected), do: {:error, :stale_generation}

  defp valid_transition(current, target) do
    if target in Map.get(@transitions, current, []),
      do: :ok,
      else: {:error, :invalid_memory_transition}
  end

  defp require_active(%Record{status: "active"}), do: :ok
  defp require_active(_record), do: {:error, :memory_not_active}

  defp require_terminal(%Record{status: status}) when status in @terminal_statuses, do: :ok
  defp require_terminal(_record), do: {:error, :memory_not_terminal}

  defp ensure_replacement_differs(record, prepared) do
    if record.category == prepared.category and
         record.claim_fingerprint == fingerprint(prepared.category, prepared.claim),
       do: {:error, :duplicate_memory},
       else: :ok
  end

  defp enforce_record_limit(owner_id) do
    if Repo.aggregate(from(record in Record, where: record.owner_visitor_id == ^owner_id), :count) <
         @maximum_records_per_owner,
       do: :ok,
       else: {:error, :memory_record_limit_reached}
  end

  defp validate_snapshot(%Visitor{id: owner_id}, %Snapshot{} = snapshot) do
    with {:ok, stored} <- load_snapshot(%Visitor{id: owner_id}, snapshot.ref),
         true <- stored == snapshot do
      :ok
    else
      _invalid -> {:error, :scope_refused}
    end
  end

  defp bounded_limit(options, maximum) when is_list(options) do
    limit = Keyword.get(options, :limit, maximum)
    if is_integer(limit) and limit in 1..maximum, do: {:ok, limit}, else: {:error, :invalid_limit}
  end

  defp bounded_limit(_options, _maximum), do: {:error, :invalid_limit}

  defp fingerprint(category, claim),
    do: :crypto.hash(:sha256, category <> "\0" <> String.downcase(claim))

  defp active_record(owner_id, category, claim) do
    claim_fingerprint = fingerprint(category, claim)

    Repo.one(
      from(record in Record,
        where:
          record.owner_visitor_id == ^owner_id and record.category == ^category and
            record.claim_fingerprint == ^claim_fingerprint and record.status == "active",
        lock: "FOR UPDATE"
      )
    )
  end

  defp active_records_for_forget(owner_id, %{"mode" => "record", "record_id" => record_id}) do
    query =
      from(record in Record,
        where:
          record.owner_visitor_id == ^owner_id and record.id == ^record_id and
            record.status == "active",
        lock: "FOR UPDATE"
      )

    {:ok, Repo.all(query)}
  end

  defp active_records_for_forget(owner_id, %{"mode" => "category", "category" => category})
       when category in ~w(name role project preference constraint other) do
    {:ok,
     Repo.all(
       from(record in Record,
         where:
           record.owner_visitor_id == ^owner_id and record.category == ^category and
             record.status == "active",
         order_by: [asc: record.id],
         lock: "FOR UPDATE"
       )
     )}
  end

  defp active_records_for_forget(owner_id, %{"mode" => "all"}) do
    {:ok,
     Repo.all(
       from(record in Record,
         where: record.owner_visitor_id == ^owner_id and record.status == "active",
         order_by: [asc: record.id],
         lock: "FOR UPDATE"
       )
     )}
  end

  defp active_records_for_forget(_owner_id, _selector), do: {:error, :invalid_forget_selector}

  defp validate_forget_generation([], _selector), do: :ok

  defp validate_forget_generation([record], %{
         "mode" => "record",
         "expected_generation" => expected_generation
       })
       when is_integer(expected_generation),
       do: generation_matches(record, expected_generation)

  defp validate_forget_generation(_records, %{"mode" => mode}) when mode in ["category", "all"],
    do: :ok

  defp validate_forget_generation(_records, _selector), do: {:error, :invalid_forget_selector}

  defp forget_records(records, scope_generation) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, forgotten} ->
      case apply_transition(record, "forgotten", scope_generation) do
        {:ok, updated} -> {:cont, {:ok, [updated | forgotten]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, forgotten} -> {:ok, Enum.reverse(forgotten)}
      error -> error
    end
  end

  defp snapshot_ref(snapshot_id), do: "profile-memory-snapshot:v1:#{snapshot_id}"

  defp export_record(record) do
    {claim, projection, withheld_reason} = project_claim(record.claim)

    %{
      "id" => record.id,
      "schema_version" => record.schema_version,
      "category" => record.category,
      "claim" => claim,
      "projection" => projection,
      "withheld_reason" => withheld_reason,
      "status" => record.status,
      "provenance" => %{
        "basis" => if(record.owner_asserted_at, do: "owner_assertion", else: "source_linked"),
        "creator" => record.creator,
        "supersedes_record_id" => record.supersedes_record_id
      },
      "confidence" => Decimal.to_float(record.confidence),
      "valid_from" => encode_time(record.valid_from),
      "valid_until" => encode_time(record.valid_until),
      "confirmed_at" => encode_time(record.confirmed_at),
      "expires_at" => encode_time(record.expires_at),
      "owner_asserted_at" => encode_time(record.owner_asserted_at),
      "redaction_policy" => record.redaction_policy,
      "policy_version" => record.policy_version,
      "creator" => record.creator,
      "creator_artifact_id" => record.creator_artifact_id,
      "creator_artifact_digest" => record.creator_artifact_digest,
      "generation" => record.generation,
      "inserted_at" => encode_time(record.inserted_at),
      "updated_at" => encode_time(record.updated_at),
      "supersedes_record_id" => record.supersedes_record_id,
      "sources" => Enum.map(record.sources, &project_source/1)
    }
  end

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp project_claim(claim) do
    case Redaction.project(claim) do
      {:ok, safe} -> {safe, "admitted", nil}
      {:withheld, reason} -> {nil, "withheld", reason}
    end
  end

  defp project_source(source) do
    case Redaction.project(source.message.content) do
      {:ok, _safe} ->
        %{
          "source_ref" => "message:#{source.message_id}",
          "kind" => source.source_kind,
          "observed_at" => encode_time(source.message.inserted_at),
          "projection" => "admitted",
          "withheld_reason" => nil
        }

      {:withheld, reason} ->
        %{
          "source_ref" => nil,
          "kind" => source.source_kind,
          "observed_at" => encode_time(source.message.inserted_at),
          "projection" => "withheld",
          "withheld_reason" => reason
        }
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp transaction(function) do
    case Repo.transaction(fn ->
           case function.() do
             {:error, reason} -> Repo.rollback(reason)
             result -> result
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast_result(owner, {:ok, result} = success) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      @topic_prefix <> owner.id,
      {:profile_memory_updated, result}
    )

    success
  end

  defp broadcast_result(_owner, error), do: error
end
