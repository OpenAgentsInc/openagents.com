defmodule OpenAgents.GraphMemory do
  @moduledoc "Derived, generation-pinned relationship index over authoritative private experience."

  import Ecto.Query

  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.ExperienceMemory.{Pattern, PatternSupport, Record, Scope}

  alias OpenAgents.GraphMemory.{
    Artifact,
    CascadePlan,
    Manifest,
    OperationReceipt,
    SourceMembership
  }

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @policy_id "sarah.graph.derived.v1"
  @policy_version 1

  def rebuild(%Visitor{} = owner, work_scope), do: build(owner, work_scope, "rebuild")
  def replay(%Visitor{} = owner, work_scope), do: build(owner, work_scope, "replay")

  def recover(%Visitor{} = owner, work_scope) do
    with {:ok, _} <- owned_scope(owner.id, work_scope) do
      transaction(fn ->
        advisory_lock!(owner.id, work_scope)
        now = DateTime.utc_now()

        incomplete =
          Repo.all(
            from(m in Manifest,
              where:
                m.owner_visitor_id == ^owner.id and m.work_scope == ^work_scope and
                  m.status == "building",
              order_by: [asc: m.generation],
              lock: "FOR UPDATE"
            )
          )

        receipts =
          Enum.map(incomplete, fn manifest ->
            failed =
              update!(
                Manifest.transition_changeset(manifest, %{
                  status: "failed",
                  failure_code: "incomplete_build_recovered",
                  built_at: now
                })
              )

            receipt!(owner.id, work_scope, "recover", failed, nil, 0, 0)
          end)

        %{recovered: length(incomplete), receipts: receipts}
      end)
    end
  end

  def traverse(%Visitor{} = owner, work_scope, start_node_id, options \\ []) do
    config = Application.fetch_env!(:sarah, :graph_memory)

    with true <- Keyword.fetch!(config, :enabled) or {:error, :graph_memory_disabled},
         {:ok, _} <- owned_scope(owner.id, work_scope),
         {:ok, maximum_depth} <-
           bounded_option(options, :depth, 1, Keyword.fetch!(config, :maximum_depth)),
         {:ok, maximum_nodes} <-
           bounded_option(options, :limit, 1, Keyword.fetch!(config, :maximum_nodes)),
         %Manifest{} = manifest <- current_manifest(owner.id, work_scope),
         %Artifact{kind: "node"} = start <- artifact(manifest.id, start_node_id),
         true <-
           allowed_artifact?(owner.id, work_scope, manifest.id, start) or
             {:error, :source_policy_excluded} do
      visited =
        walk(
          manifest,
          owner.id,
          work_scope,
          [start.artifact_id],
          MapSet.new(),
          maximum_depth,
          maximum_nodes
        )

      {:ok, traversal_projection(manifest, visited, maximum_nodes)}
    else
      nil -> {:error, :graph_unavailable}
      false -> {:error, :graph_unavailable}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :graph_start_not_found}
    end
  end

  def inspect(%Visitor{} = owner, work_scope), do: export(owner, work_scope)

  def export(%Visitor{} = owner, work_scope) do
    maximum =
      Application.fetch_env!(:sarah, :graph_memory) |> Keyword.fetch!(:maximum_export_artifacts)

    with {:ok, _} <- owned_scope(owner.id, work_scope),
         %Manifest{} = manifest <- current_manifest(owner.id, work_scope) do
      rows =
        Repo.all(
          from(a in Artifact,
            where: a.manifest_id == ^manifest.id,
            order_by: [asc: a.kind, asc: a.artifact_id],
            limit: ^maximum
          )
        )

      {:ok,
       %{
         "schema" => "sarah.graph_export.v1",
         "manifest" => manifest_projection(manifest),
         "artifacts" => Enum.map(rows, &artifact_projection(manifest.id, &1)),
         "truncated" => length(rows) == maximum
       }}
    else
      nil -> {:error, :graph_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def plan_cascade(%Visitor{} = owner, work_scope, source_ref) do
    with {:ok, _} <- owned_scope(owner.id, work_scope),
         {:ok, source_ref} <- source_ref(source_ref),
         %Manifest{} = manifest <- current_manifest(owner.id, work_scope) do
      transaction(fn ->
        locked = manifest_for_update!(manifest.id, owner.id, work_scope)
        direct = membership_artifact_ids(locked.id, source_ref)

        orphan_nodes =
          direct
          |> Enum.filter(&artifact_kind?(locked.id, &1, "node"))
          |> Enum.filter(&(membership_count(locked.id, &1) == 1))

        incident_edges =
          Repo.all(
            from(a in Artifact,
              where:
                a.manifest_id == ^locked.id and a.kind == "edge" and
                  (a.source_node_id in ^orphan_nodes or a.target_node_id in ^orphan_nodes),
              select: a.artifact_id
            )
          )

        delete_ids =
          direct
          |> Enum.filter(&(membership_count(locked.id, &1) == 1))
          |> Kernel.++(incident_edges)
          |> Enum.uniq()
          |> Enum.sort()

        counts = artifact_counts(locked.id, delete_ids)

        projection = %{
          "owner_visitor_id" => owner.id,
          "work_scope" => work_scope,
          "manifest_id" => locked.id,
          "source_ref" => source_ref,
          "source_snapshot_digest" => locked.source_snapshot_digest,
          "artifact_ids" => delete_ids,
          "node_count" => counts.nodes,
          "edge_count" => counts.edges
        }

        insert!(
          CascadePlan.create_changeset(
            %CascadePlan{},
            projection
            |> Map.put("plan_digest", Canonical.digest!(projection))
            |> Map.put("status", "planned")
          )
        )
      end)
    else
      nil -> {:error, :graph_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_cascade(%Visitor{} = owner, plan_id) do
    result =
      transaction(fn ->
        plan =
          Repo.one(
            from(p in CascadePlan,
              where: p.id == ^plan_id and p.owner_visitor_id == ^owner.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:cascade_plan_not_found)

        if plan.status != "planned", do: Repo.rollback(:cascade_plan_not_active)

        if source_exists?(owner.id, plan.work_scope, plan.source_ref),
          do: Repo.rollback(:source_still_authoritative)

        manifest = manifest_for_update!(plan.manifest_id, owner.id, plan.work_scope)

        if manifest.status != "current" or
             manifest.source_snapshot_digest != plan.source_snapshot_digest do
          stale =
            update!(
              CascadePlan.apply_changeset(plan, %{status: "stale", applied_at: DateTime.utc_now()})
            )

          {:cascade_stale, stale}
        else
          current_ids =
            plan.artifact_ids |> Enum.filter(&artifact_exists?(manifest.id, &1)) |> Enum.sort()

          counts = artifact_counts(manifest.id, current_ids)

          Repo.delete_all(
            from(m in SourceMembership,
              where: m.manifest_id == ^manifest.id and m.source_ref == ^plan.source_ref
            )
          )

          Repo.delete_all(
            from(a in Artifact,
              where: a.manifest_id == ^manifest.id and a.artifact_id in ^current_ids
            )
          )

          now = DateTime.utc_now()
          update!(Manifest.transition_changeset(manifest, %{status: "retired"}))

          applied =
            update!(CascadePlan.apply_changeset(plan, %{status: "applied", applied_at: now}))

          receipt!(
            owner.id,
            plan.work_scope,
            "cascade",
            manifest,
            applied,
            counts.nodes,
            counts.edges
          )
        end
      end)

    case result do
      {:ok, {:cascade_stale, _plan}} -> {:error, :cascade_plan_stale}
      other -> other
    end
  end

  def drop_derived_scope(%Visitor{} = owner, work_scope) do
    with {:ok, _} <- owned_scope(owner.id, work_scope) do
      transaction(fn ->
        manifests =
          Repo.all(
            from(m in Manifest,
              where: m.owner_visitor_id == ^owner.id and m.work_scope == ^work_scope,
              lock: "FOR UPDATE"
            )
          )

        counts = scope_artifact_counts(Enum.map(manifests, & &1.id))

        snapshot =
          manifests |> Enum.map(& &1.source_snapshot_digest) |> Enum.sort() |> Canonical.digest!()

        Repo.delete_all(from(m in Manifest, where: m.id in ^Enum.map(manifests, & &1.id)))
        receipt!(owner.id, work_scope, "drop", nil, nil, counts.nodes, counts.edges, snapshot)
      end)
    end
  end

  defp build(owner, work_scope, operation) do
    config = Application.fetch_env!(:sarah, :graph_memory)

    with true <- Keyword.fetch!(config, :enabled) or {:error, :graph_memory_disabled},
         {:ok, _} <- owned_scope(owner.id, work_scope) do
      transaction(fn ->
        advisory_lock!(owner.id, work_scope)
        _source_scope = source_scope_for_update!(owner.id, work_scope)
        source = source_snapshot(owner.id, work_scope)
        generation = next_generation(owner.id, work_scope)

        manifest =
          insert!(
            Manifest.create_changeset(%Manifest{}, %{
              owner_visitor_id: owner.id,
              work_scope: work_scope,
              generation: generation,
              status: "building",
              policy_id: @policy_id,
              policy_version: @policy_version,
              source_snapshot_digest: source.digest,
              node_count: 0,
              edge_count: 0
            })
          )

        graph = project(owner.id, work_scope, source)
        persist_graph!(manifest, owner.id, work_scope, graph)
        build_digest = graph_digest(graph)
        now = DateTime.utc_now()

        Repo.update_all(
          from(m in Manifest,
            where:
              m.owner_visitor_id == ^owner.id and m.work_scope == ^work_scope and
                m.status == "current"
          ),
          set: [status: "retired", updated_at: now]
        )

        current =
          update!(
            Manifest.transition_changeset(manifest, %{
              status: "current",
              build_digest: build_digest,
              node_count: graph.node_count,
              edge_count: graph.edge_count,
              built_at: now
            })
          )

        Repo.update_all(
          from(o in OpenAgents.GraphMemory.OutboxEvent,
            where:
              o.owner_visitor_id == ^owner.id and o.work_scope == ^work_scope and
                o.status == "pending"
          ),
          set: [
            status: "consumed",
            consumed_manifest_id: current.id,
            consumed_at: now,
            updated_at: now
          ]
        )

        receipt = receipt!(owner.id, work_scope, operation, current, nil, 0, 0)
        %{manifest: current, receipt: receipt}
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_snapshot(owner_id, work_scope) do
    now = DateTime.utc_now()

    records =
      Repo.all(
        from(r in Record,
          where: r.owner_visitor_id == ^owner_id and r.work_scope == ^work_scope,
          order_by: [asc: r.id]
        )
      )

    patterns =
      Repo.all(
        from(p in Pattern,
          where: p.owner_visitor_id == ^owner_id and p.work_scope == ^work_scope,
          order_by: [asc: p.id]
        )
      )

    pattern_ids = Enum.map(patterns, & &1.id)

    supports =
      Repo.all(
        from(s in PatternSupport,
          where: s.pattern_id in ^pattern_ids,
          order_by: [asc: s.pattern_id, asc: s.record_id]
        )
      )

    projection = %{
      "records" =>
        Enum.map(
          records,
          &%{
            "id" => &1.id,
            "digest" => &1.content_digest,
            "generation" => &1.generation,
            "state" => &1.outcome_state
          }
        ),
      "patterns" =>
        Enum.map(
          patterns,
          &%{
            "id" => &1.id,
            "digest" => &1.digest,
            "generation" => &1.generation,
            "status" => &1.status
          }
        ),
      "supports" =>
        Enum.map(
          supports,
          &%{
            "pattern_id" => &1.pattern_id,
            "record_id" => &1.record_id,
            "state" => &1.outcome_state
          }
        )
    }

    %{
      records: records,
      patterns: patterns,
      supports: supports,
      at: now,
      digest: Canonical.digest!(projection)
    }
  end

  defp project(owner_id, work_scope, source) do
    initial = %{artifacts: %{}, memberships: MapSet.new()}
    record_ids = MapSet.new(Enum.map(source.records, & &1.id))

    graph =
      Enum.reduce(source.records, initial, fn record, acc ->
        case_ref = "experience:#{record.id}"
        source_info = {"experience_record", case_ref, record.content_digest}
        case_id = node_id(owner_id, work_scope, "work_case", case_ref)
        objective_key = fingerprint(record.objective)
        approach_key = fingerprint(record.approach)
        applicability_key = fingerprint(record.applicability)
        objective_id = node_id(owner_id, work_scope, "objective", objective_key)
        approach_id = node_id(owner_id, work_scope, "approach", approach_key)
        applicability_id = node_id(owner_id, work_scope, "applicability", applicability_key)

        eligible =
          record.outcome_state in ["succeeded", "failed"] and
            (is_nil(record.retention_until) or DateTime.after?(record.retention_until, source.at))

        acc
        |> add_node(
          owner_id,
          work_scope,
          case_id,
          "work_case",
          case_ref,
          Integer.to_string(record.generation),
          objective_key,
          %{
            "state" => record.outcome_state,
            "outcome" => clip(record.outcome),
            "eligible_for_traversal" => eligible
          },
          source_info
        )
        |> add_node(
          owner_id,
          work_scope,
          objective_id,
          "objective",
          objective_key,
          "1",
          objective_key,
          %{"label" => clip(record.objective)},
          source_info
        )
        |> add_node(
          owner_id,
          work_scope,
          approach_id,
          "approach",
          approach_key,
          "1",
          approach_key,
          %{"label" => clip(record.approach)},
          source_info
        )
        |> add_node(
          owner_id,
          work_scope,
          applicability_id,
          "applicability",
          applicability_key,
          "1",
          applicability_key,
          %{"label" => clip(record.applicability)},
          source_info
        )
        |> add_edge(owner_id, work_scope, case_id, objective_id, "pursues", %{}, source_info)
        |> add_edge(
          owner_id,
          work_scope,
          case_id,
          approach_id,
          "used_approach",
          %{"outcome_state" => record.outcome_state},
          source_info
        )
        |> add_edge(
          owner_id,
          work_scope,
          case_id,
          applicability_id,
          "applies_when",
          %{},
          source_info
        )
        |> maybe_add_correction(owner_id, work_scope, record, record_ids, case_id, source_info)
      end)

    graph =
      Enum.reduce(source.patterns, graph, fn pattern, acc ->
        source_ref = "experience-pattern:#{pattern.id}"
        source_info = {"experience_pattern", source_ref, pattern.digest}
        pattern_id = node_id(owner_id, work_scope, "pattern", source_ref)

        add_node(
          acc,
          owner_id,
          work_scope,
          pattern_id,
          "pattern",
          source_ref,
          Integer.to_string(pattern.generation),
          fingerprint(pattern.phenomenon),
          %{
            "phenomenon" => clip(pattern.phenomenon),
            "applicability" => clip(pattern.applicability),
            "expected_effect" => clip(pattern.expected_effect),
            "status" => pattern.status,
            "eligible_for_traversal" => pattern.status == "active"
          },
          source_info
        )
      end)

    graph =
      Enum.reduce(source.supports, graph, fn support, acc ->
        pattern = Enum.find(source.patterns, &(&1.id == support.pattern_id))
        record = Enum.find(source.records, &(&1.id == support.record_id))

        if pattern && record do
          pattern_id =
            node_id(owner_id, work_scope, "pattern", "experience-pattern:#{pattern.id}")

          record_id = node_id(owner_id, work_scope, "work_case", "experience:#{record.id}")

          pattern_source =
            {"experience_pattern", "experience-pattern:#{pattern.id}", pattern.digest}

          record_source = {"experience_record", "experience:#{record.id}", record.content_digest}

          acc
          |> add_edge(
            owner_id,
            work_scope,
            pattern_id,
            record_id,
            "supported_by",
            %{"outcome_state" => support.outcome_state},
            pattern_source
          )
          |> add_membership(edge_id(pattern_id, record_id, "supported_by"), record_source)
        else
          acc
        end
      end)

    counts =
      Enum.reduce(graph.artifacts, %{node_count: 0, edge_count: 0}, fn {_id, row}, counts ->
        Map.update!(counts, if(row.kind == "node", do: :node_count, else: :edge_count), &(&1 + 1))
      end)

    Map.merge(graph, counts)
  end

  defp maybe_add_correction(acc, owner_id, work_scope, record, record_ids, case_id, source_info) do
    if record.supersedes_record_id && MapSet.member?(record_ids, record.supersedes_record_id) do
      old_id =
        node_id(owner_id, work_scope, "work_case", "experience:#{record.supersedes_record_id}")

      add_edge(acc, owner_id, work_scope, old_id, case_id, "superseded_by", %{}, source_info)
    else
      acc
    end
  end

  defp add_node(
         acc,
         owner_id,
         work_scope,
         id,
         entity_kind,
         identity_key,
         version_key,
         conflict_key,
         properties,
         source
       ),
       do:
         put_artifact(
           acc,
           id,
           %{
             kind: "node",
             entity_kind: entity_kind,
             identity_key: identity_key,
             version_key: version_key,
             conflict_key: conflict_key,
             source_node_id: nil,
             target_node_id: nil,
             predicate: nil,
             properties: properties
           },
           owner_id,
           work_scope,
           source
         )

  defp add_edge(acc, owner_id, work_scope, source_id, target_id, predicate, properties, source) do
    id = edge_id(source_id, target_id, predicate)

    put_artifact(
      acc,
      id,
      %{
        kind: "edge",
        entity_kind: nil,
        identity_key: nil,
        version_key: nil,
        conflict_key: nil,
        source_node_id: source_id,
        target_node_id: target_id,
        predicate: predicate,
        properties: properties
      },
      owner_id,
      work_scope,
      source
    )
  end

  defp put_artifact(acc, id, shape, owner_id, work_scope, source) do
    projection =
      Map.merge(shape, %{artifact_id: id, owner_visitor_id: owner_id, work_scope: work_scope})

    row = Map.put(projection, :artifact_digest, Canonical.digest!(string_keys(projection)))
    %{acc | artifacts: Map.put_new(acc.artifacts, id, row)} |> add_membership(id, source)
  end

  defp add_membership(acc, artifact_id, {kind, ref, digest}),
    do: %{acc | memberships: MapSet.put(acc.memberships, {artifact_id, kind, ref, digest})}

  defp persist_graph!(manifest, owner_id, work_scope, graph) do
    graph.artifacts
    |> Map.values()
    |> Enum.sort_by(& &1.artifact_id)
    |> Enum.each(fn row ->
      insert!(Artifact.changeset(%Artifact{}, row |> Map.put(:manifest_id, manifest.id)))
    end)

    graph.memberships
    |> Enum.sort()
    |> Enum.each(fn {artifact_id, source_kind, source_ref, source_digest} ->
      insert!(
        SourceMembership.changeset(%SourceMembership{}, %{
          manifest_id: manifest.id,
          artifact_id: artifact_id,
          owner_visitor_id: owner_id,
          work_scope: work_scope,
          source_kind: source_kind,
          source_ref: source_ref,
          source_digest: source_digest
        })
      )
    end)
  end

  defp graph_digest(graph),
    do:
      Canonical.digest!(%{
        "artifacts" =>
          graph.artifacts |> Map.values() |> Enum.map(& &1.artifact_digest) |> Enum.sort(),
        "memberships" =>
          graph.memberships
          |> Enum.map(fn {id, kind, ref, digest} -> [id, kind, ref, digest] end)
          |> Enum.sort()
      })

  defp walk(_manifest, _owner_id, _scope, [], visited, _depth, _limit), do: visited
  defp walk(_manifest, _owner_id, _scope, _frontier, visited, 0, _limit), do: visited

  defp walk(manifest, owner_id, scope, frontier, visited, depth, limit) do
    remaining = limit - MapSet.size(visited)

    if remaining <= 0 do
      visited
    else
      walk_remaining(manifest, owner_id, scope, frontier, visited, depth, limit, remaining)
    end
  end

  defp walk_remaining(manifest, owner_id, scope, frontier, visited, depth, limit, remaining) do
    nodes = frontier |> Enum.reject(&MapSet.member?(visited, &1)) |> Enum.take(remaining)
    visited = Enum.reduce(nodes, visited, &MapSet.put(&2, &1))

    edges =
      Repo.all(
        from(a in Artifact,
          where:
            a.manifest_id == ^manifest.id and a.kind == "edge" and a.source_node_id in ^nodes,
          order_by: [asc: a.artifact_id]
        )
      )

    allowed_edges = Enum.filter(edges, &allowed_artifact?(owner_id, scope, manifest.id, &1))

    edge_ids =
      allowed_edges |> Enum.map(& &1.artifact_id) |> Enum.take(limit - MapSet.size(visited))

    visited = Enum.reduce(edge_ids, visited, &MapSet.put(&2, &1))

    targets =
      allowed_edges
      |> Enum.map(& &1.target_node_id)
      |> Enum.uniq()
      |> Enum.filter(fn id ->
        case artifact(manifest.id, id) do
          nil -> false
          row -> allowed_artifact?(owner_id, scope, manifest.id, row)
        end
      end)

    walk(manifest, owner_id, scope, targets, visited, depth - 1, limit)
  end

  defp allowed_artifact?(owner_id, work_scope, manifest_id, artifact) do
    memberships =
      Repo.all(
        from(m in SourceMembership,
          where: m.manifest_id == ^manifest_id and m.artifact_id == ^artifact.artifact_id
        )
      )

    memberships != [] and Enum.all?(memberships, &source_allowed?(owner_id, work_scope, &1))
  end

  defp source_allowed?(owner_id, work_scope, %{
         source_kind: "experience_record",
         source_ref: "experience:" <> id
       }) do
    now = DateTime.utc_now()

    Repo.exists?(
      from(r in Record,
        where:
          r.id == ^id and r.owner_visitor_id == ^owner_id and r.work_scope == ^work_scope and
            r.outcome_state in ["succeeded", "failed"] and
            (is_nil(r.retention_until) or r.retention_until > ^now)
      )
    )
  end

  defp source_allowed?(owner_id, work_scope, %{
         source_kind: "experience_pattern",
         source_ref: "experience-pattern:" <> id
       }),
       do:
         Repo.exists?(
           from(p in Pattern,
             where:
               p.id == ^id and p.owner_visitor_id == ^owner_id and p.work_scope == ^work_scope and
                 p.status == "active"
           )
         )

  defp source_allowed?(_, _, _), do: false

  defp traversal_projection(manifest, visited, maximum) do
    rows =
      Repo.all(
        from(a in Artifact,
          where: a.manifest_id == ^manifest.id and a.artifact_id in ^MapSet.to_list(visited),
          order_by: [asc: a.kind, asc: a.artifact_id]
        )
      )

    %{
      "schema" => "sarah.graph_traversal.v1",
      "manifest_ref" => manifest_ref(manifest),
      "artifacts" => Enum.map(rows, &artifact_projection(manifest.id, &1)),
      "truncated" => MapSet.size(visited) >= maximum
    }
  end

  defp artifact_projection(manifest_id, artifact),
    do: %{
      "artifact_id" => artifact.artifact_id,
      "kind" => artifact.kind,
      "entity_kind" => artifact.entity_kind,
      "identity_key" => artifact.identity_key,
      "version_key" => artifact.version_key,
      "conflict_key" => artifact.conflict_key,
      "source_node_id" => artifact.source_node_id,
      "target_node_id" => artifact.target_node_id,
      "predicate" => artifact.predicate,
      "properties" => artifact.properties,
      "source_refs" =>
        Repo.all(
          from(m in SourceMembership,
            where: m.manifest_id == ^manifest_id and m.artifact_id == ^artifact.artifact_id,
            order_by: [asc: m.source_ref],
            select: m.source_ref
          )
        )
    }

  defp manifest_projection(manifest),
    do: %{
      "ref" => manifest_ref(manifest),
      "generation" => manifest.generation,
      "policy_id" => manifest.policy_id,
      "policy_version" => manifest.policy_version,
      "source_snapshot_digest" => manifest.source_snapshot_digest,
      "build_digest" => manifest.build_digest,
      "node_count" => manifest.node_count,
      "edge_count" => manifest.edge_count
    }

  defp manifest_ref(manifest), do: "graph-manifest:v1:#{manifest.id}"

  defp receipt!(
         owner_id,
         scope,
         operation,
         manifest,
         plan,
         deleted_nodes,
         deleted_edges,
         snapshot \\ nil
       ) do
    projection = %{
      "owner_visitor_id" => owner_id,
      "work_scope" => scope,
      "operation" => operation,
      "manifest_ref" => if(manifest, do: manifest_ref(manifest)),
      "plan_ref" => if(plan, do: "graph-cascade-plan:v1:#{plan.id}"),
      "source_snapshot_digest" => snapshot || manifest.source_snapshot_digest,
      "deleted_node_count" => deleted_nodes,
      "deleted_edge_count" => deleted_edges
    }

    insert!(
      OperationReceipt.changeset(
        %OperationReceipt{},
        Map.put(projection, "receipt_digest", Canonical.digest!(projection))
      )
    )
  end

  defp current_manifest(owner_id, scope) do
    pending? =
      Repo.exists?(
        from(o in OpenAgents.GraphMemory.OutboxEvent,
          where:
            o.owner_visitor_id == ^owner_id and o.work_scope == ^scope and o.status == "pending"
        )
      )

    if pending? do
      nil
    else
      Repo.one(
        from(m in Manifest,
          where:
            m.owner_visitor_id == ^owner_id and m.work_scope == ^scope and m.status == "current"
        )
      )
    end
  end

  defp manifest_for_update!(id, owner_id, scope),
    do:
      Repo.one(
        from(m in Manifest,
          where: m.id == ^id and m.owner_visitor_id == ^owner_id and m.work_scope == ^scope,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:graph_manifest_not_found)

  defp artifact(manifest_id, artifact_id),
    do: Repo.get_by(Artifact, manifest_id: manifest_id, artifact_id: artifact_id)

  defp artifact_exists?(manifest_id, id),
    do:
      Repo.exists?(
        from(a in Artifact, where: a.manifest_id == ^manifest_id and a.artifact_id == ^id)
      )

  defp artifact_kind?(manifest_id, id, kind),
    do:
      Repo.exists?(
        from(a in Artifact,
          where: a.manifest_id == ^manifest_id and a.artifact_id == ^id and a.kind == ^kind
        )
      )

  defp membership_artifact_ids(manifest_id, source_ref),
    do:
      Repo.all(
        from(m in SourceMembership,
          where: m.manifest_id == ^manifest_id and m.source_ref == ^source_ref,
          select: m.artifact_id
        )
      )
      |> Enum.uniq()

  defp membership_count(manifest_id, artifact_id),
    do:
      Repo.aggregate(
        from(m in SourceMembership,
          where: m.manifest_id == ^manifest_id and m.artifact_id == ^artifact_id
        ),
        :count
      )

  defp artifact_counts(_manifest_id, []), do: %{nodes: 0, edges: 0}

  defp artifact_counts(manifest_id, ids),
    do: %{
      nodes:
        Repo.aggregate(
          from(a in Artifact,
            where: a.manifest_id == ^manifest_id and a.artifact_id in ^ids and a.kind == "node"
          ),
          :count
        ),
      edges:
        Repo.aggregate(
          from(a in Artifact,
            where: a.manifest_id == ^manifest_id and a.artifact_id in ^ids and a.kind == "edge"
          ),
          :count
        )
    }

  defp scope_artifact_counts([]), do: %{nodes: 0, edges: 0}

  defp scope_artifact_counts(ids),
    do: %{
      nodes:
        Repo.aggregate(
          from(a in Artifact, where: a.manifest_id in ^ids and a.kind == "node"),
          :count
        ),
      edges:
        Repo.aggregate(
          from(a in Artifact, where: a.manifest_id in ^ids and a.kind == "edge"),
          :count
        )
    }

  defp source_exists?(owner_id, scope, "experience:" <> id),
    do:
      Repo.exists?(
        from(r in Record,
          where: r.id == ^id and r.owner_visitor_id == ^owner_id and r.work_scope == ^scope
        )
      )

  defp source_exists?(owner_id, scope, "experience-pattern:" <> id),
    do:
      Repo.exists?(
        from(p in Pattern,
          where: p.id == ^id and p.owner_visitor_id == ^owner_id and p.work_scope == ^scope
        )
      )

  defp source_exists?(_, _, _), do: true

  defp source_ref("experience:" <> id = ref),
    do:
      if(match?({:ok, _}, Ecto.UUID.cast(id)),
        do: {:ok, ref},
        else: {:error, :invalid_source_ref}
      )

  defp source_ref("experience-pattern:" <> id = ref),
    do:
      if(match?({:ok, _}, Ecto.UUID.cast(id)),
        do: {:ok, ref},
        else: {:error, :invalid_source_ref}
      )

  defp source_ref(_), do: {:error, :invalid_source_ref}

  defp owned_scope(owner_id, "conversation:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, parsed} ->
        if Repo.exists?(
             from(c in Conversation, where: c.id == ^parsed and c.visitor_id == ^owner_id)
           ), do: {:ok, parsed}, else: {:error, :scope_refused}

      :error ->
        {:error, :scope_refused}
    end
  end

  defp owned_scope(_, _), do: {:error, :scope_refused}

  defp source_scope_for_update!(owner_id, work_scope) do
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
      {:ok, _} ->
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

  defp advisory_lock!(owner_id, scope),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        owner_id <> ":" <> scope
      ])

  defp next_generation(owner_id, scope),
    do:
      (Repo.one(
         from(m in Manifest,
           where: m.owner_visitor_id == ^owner_id and m.work_scope == ^scope,
           select: max(m.generation)
         )
       ) || 0) + 1

  defp node_id(owner, scope, kind, identity),
    do: Canonical.sha256("graph-node:v1:#{owner}:#{scope}:#{kind}:#{identity}")

  defp edge_id(source, target, predicate),
    do: Canonical.sha256("graph-edge:v1:#{source}:#{predicate}:#{target}")

  defp fingerprint(text),
    do:
      Canonical.sha256(
        text
        |> String.normalize(:nfkc)
        |> String.downcase()
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()
      )

  defp clip(nil), do: ""
  defp clip(text), do: text |> String.slice(0, 400)
  defp string_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp bounded_option(options, key, minimum, maximum) do
    value = Keyword.get(options, key, maximum)

    if is_integer(value) and value in minimum..maximum,
      do: {:ok, value},
      else: {:error, :invalid_graph_bound}
  end

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
