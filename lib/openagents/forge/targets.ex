defmodule OpenAgents.Forge.Targets do
  @moduledoc """
  Fleet-target promotion: which pushed commit the fleet should be running.

  Promotion is an operator action — the human approval seam of the deploy
  pipeline (roadmap P2). Targets are append-only rows; the newest row per
  repo is the current target, so "pin back to a known-good SHA" is just
  another promotion, receipted like any other. Status advances through the
  deploy lane (`promoted → building → built → deploying →
  live | failed | reverted | needs_rolling_replace`) with bounded details
  at every step. An operator-approved relup or rolling replacement can settle
  a `needs_rolling_replace` target as `live` or `failed` with a second
  immutable receipt. The `forge:target` broadcast is what wakes the builder.
  """

  import Ecto.Query

  alias OpenAgents.Analytics
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Forge.{Pushes, Target}
  alias OpenAgents.Repo

  @statuses ~w(promoted building built deploying live failed reverted needs_rolling_replace)

  @rolling_authority_schema "openagents.forge.rolling-authority.v1"

  @doc "All target statuses, in lifecycle order."
  def statuses, do: @statuses

  @doc """
  Promote a pushed commit as the fleet target for `repo`. `operator` is the
  promoting identity (immutable operator id or a test principal).

  Verifies the SHA is actually in the WAL-backed repo — only pushed commits
  are ever promotable (SELF-EDIT precondition, enforced from day one).

  `commit_store` is an optional `{repo, sha} -> :ok | :error | {:error, reason}`
  function that decides *existence*. It defaults to the real WAL-backed repo
  check in every environment, test included: an env-dependent bypass would
  mean the precondition is never actually exercised. The SHA *format* check
  is not part of the store and always runs, so an injected store can never
  widen what a well-formed SHA is.
  """
  def promote(repo, sha, operator, opts \\ [])
      when is_binary(repo) and is_binary(sha) and is_list(opts) do
    commit_store = Keyword.get(opts, :commit_store, &commit_exists_store/2)
    details = Keyword.get(opts, :details, %{}) || %{}

    with :ok <- validate_deployable_repo(repo),
         :ok <- validate_sha_format(sha),
         :ok <- with_commit_store(repo, sha, commit_store) do
      %Target{}
      |> Target.changeset(%{
        repo: repo,
        sha: sha,
        promoted_by: operator,
        status: "promoted",
        details: details
      })
      |> Repo.insert()
      |> case do
        {:ok, target} ->
          Analytics.capture("release_promoted", Analytics.system_distinct_id("forge"), %{
            "repo" => repo
          })

          broadcast_promotion(target)
          {:ok, target}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, {:invalid, changeset}}
      end
    end
  end

  @doc "Alias for the current target for a repo."
  def latest(repo), do: current(repo)

  @doc "Alias for `advance/2` with no step details."
  def transition(target_id, status), do: advance(target_id, status, %{})

  @doc "The newest target for `repo` (the current fleet target), or nil."
  def current(repo) do
    Target
    |> where([t], t.repo == ^repo)
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The newest immutable live target for `repo`, or nil."
  def live(repo) do
    Target
    |> where([t], t.repo == ^repo and t.status == "live")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Newest immutable live targets for `repo`, bounded and newest first."
  def live_history(repo, limit \\ 2) do
    Target
    |> where([t], t.repo == ^repo and t.status == "live")
    |> order_by([t], desc: t.updated_at, desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Resolve the durable authority for one committed node token."
  def deployment_authority(target_id, deployment_id, artifact_digest) do
    case Repo.get(Target, target_id) do
      %Target{
        status: "live",
        details: %{
          "deployment_id" => ^deployment_id,
          "artifact_digest" => ^artifact_digest
        }
      } ->
        :candidate_live

      %Target{status: "deploying"} ->
        :pending

      %Target{} ->
        :candidate_not_live

      nil ->
        :candidate_not_live
    end
  end

  @doc "Recent targets for a repo, newest first, bounded."
  def recent(repo, limit \\ 10) do
    Target
    |> where([t], t.repo == ^repo)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # The deploy lane's transition table doubles as its cluster-wide
  # single-writer arbiter: every node's Builder/HotLoader reacts to the same
  # broadcast, but only the first to win a legal transition (inside
  # `:global.trans`) proceeds; the rest see {:error, {:invalid_transition,..}}
  # and skip. Terminal states accept nothing.
  @transitions %{
    "promoted" => ~w(building failed),
    "building" => ~w(built failed),
    "built" => ~w(deploying needs_rolling_replace failed),
    "deploying" => ~w(live reverted needs_rolling_replace failed)
  }

  @doc """
  Advance a target's deploy status with bounded details — only along the
  legal transition table, atomically (the read-check-update runs inside a
  cluster-wide `:global.trans` on the target id).
  """
  def advance(target_id, status, details \\ %{}) when status in @statuses do
    result =
      :global.trans({{:forge_target_advance, target_id}, self()}, fn ->
        case Repo.get(Target, target_id) do
          nil ->
            {:error, :not_found}

          %Target{status: current} = target ->
            if status in Map.get(@transitions, current, []) do
              target
              |> Target.status_changeset(status, bounded_details(details))
              |> Repo.update()
            else
              {:error, {:invalid_transition, current, status}}
            end
        end
      end)

    with {:ok, target} <- result do
      broadcast_status(target)
      {:ok, target}
    end
  end

  @doc "Fence deployment ownership to the newest promoted target."
  def begin_deployment(target_id) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          current_id =
            Target
            |> where([t], t.repo == ^target.repo)
            |> order_by([t], desc: t.inserted_at)
            |> limit(1)
            |> select([t], t.id)
            |> Repo.one()

          if current_id != target.id, do: Repo.rollback(:superseded_target)

          unless target.status == "built" do
            Repo.rollback({:invalid_transition, target.status, "deploying"})
          end

          target
          |> Target.status_changeset("deploying", %{})
          |> Repo.update!()
        end)
      end)

    with {:ok, target} <- result do
      broadcast_status(target)
      {:ok, target}
    end
  end

  @doc "Atomically write a terminal deployment receipt and target status."
  def finish_deployment(target_id, status, details, receipt_attrs)
      when status in ~w(live reverted failed) and is_map(details) and is_map(receipt_attrs) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          unless target.status == "deploying" do
            Repo.rollback({:invalid_transition, target.status, status})
          end

          target =
            target
            |> Target.status_changeset(status, bounded_details(details))
            |> Repo.update!()

          receipt_attrs =
            receipt_attrs
            |> Map.put(:target_id, target.id)
            |> Map.put(:repo, target.repo)
            |> Map.put(:sha, target.sha)
            |> Map.put(:result, status)

          receipt =
            %DeployReceipt{}
            |> DeployReceipt.changeset(receipt_attrs)
            |> Repo.insert()
            |> case do
              {:ok, receipt} -> receipt
              {:error, changeset} -> Repo.rollback({:invalid_receipt, changeset})
            end

          %{target: target, receipt: receipt}
        end)
      end)

    with {:ok, %{target: target} = committed} <- result do
      broadcast_status(target)
      _ = record_deploy_evidence(committed)
      {:ok, committed}
    end
  end

  @doc """
  Settle an operator-approved relup against its verified Forge build.

  The relup coordinator returns the bounded result passed to this function.
  Settlement succeeds only for the newest target, only after Forge classified
  it as `needs_rolling_replace`, and only when a complete build receipt exists.
  The target update and the second immutable deployment receipt commit in one
  transaction. The original classification receipt remains intact.
  """
  def finish_relup_deployment(target_id, relup_result) when is_map(relup_result) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          current_id =
            Target
            |> where([t], t.repo == ^target.repo)
            |> order_by([t], desc: t.inserted_at)
            |> limit(1)
            |> select([t], t.id)
            |> Repo.one()

          if current_id != target.id, do: Repo.rollback(:superseded_target)

          unless target.status == "needs_rolling_replace" do
            requested_status = result_value(relup_result, :status) || "invalid"
            Repo.rollback({:invalid_transition, target.status, requested_status})
          end

          relup =
            case validate_relup_result(relup_result, target.sha) do
              {:ok, relup} -> relup
              {:error, reason} -> Repo.rollback(reason)
            end

          build =
            BuildReceipt
            |> where([b], b.target_id == ^target.id and b.status == "complete")
            |> order_by([b], desc: b.inserted_at)
            |> limit(1)
            |> Repo.one()

          if is_nil(build), do: Repo.rollback(:complete_build_receipt_not_found)

          deployment_id = Ecto.UUID.generate()
          now = DateTime.utc_now()

          details = %{
            "artifact_digest" => relup.artifact_digest,
            "build_artifact_digest" => build.artifact_digest,
            "deployment_id" => deployment_id,
            "deployment_lane" => "relup",
            "from_revision" => relup.from_revision,
            "from_version" => relup.from_version,
            "package_manifest_digest" => relup.package_manifest_digest,
            "relup_duration_ms" => relup.duration_ms,
            "relup_error_code" => relup.error_code,
            "relup_node_results" => relup.node_results,
            "to_version" => relup.to_version
          }

          target =
            target
            |> Target.status_changeset(relup.status, details)
            |> Repo.update!()

          receipt_attrs = %{
            artifact_digest: relup.artifact_digest,
            completed_at: now,
            deployment_id: deployment_id,
            deployment_type: "relup",
            error_code: relup.error_code,
            expected_nodes: relup.expected_nodes,
            manifest_digest: relup.package_manifest_digest,
            modules: build.modules,
            node_results: relup.node_results,
            nodes:
              Enum.map(relup.expected_nodes, fn node ->
                "#{node}=#{relup.node_results[node]}"
              end),
            push_to_live_ms: relup.duration_ms,
            repo: target.repo,
            result: relup.status,
            rollback_verified:
              relup.status == "failed" and
                Enum.all?(relup.node_results, fn {_node, status} -> status == "reversed" end),
            sha: target.sha,
            started_at: DateTime.add(now, -relup.duration_ms, :millisecond),
            target_id: target.id
          }

          receipt =
            %DeployReceipt{}
            |> DeployReceipt.changeset(receipt_attrs)
            |> Repo.insert()
            |> case do
              {:ok, receipt} -> receipt
              {:error, changeset} -> Repo.rollback({:invalid_receipt, changeset})
            end

          %{target: target, receipt: receipt}
        end)
      end)

    with {:ok, %{target: target} = committed} <- result do
      broadcast_status(target)
      _ = record_deploy_evidence(committed)
      {:ok, committed}
    end
  end

  def finish_relup_deployment(_target_id, _relup_result),
    do: {:error, :invalid_relup_result}

  @doc """
  Publish the operator-authorized rolling identity on the newest
  `needs_rolling_replace` target, before the first replacement node boots.

  The published record is the durable authority boot convergence trusts: while
  the roll runs, a node whose booted image carries exactly this source SHA and
  image digest may serve, and a node that carries neither this identity nor the
  live target's stays out of readiness. Publishing the same identity again
  resumes an interrupted roll and keeps every recorded observation. A different
  identity is accepted only while no node has been observed under the published
  one, so an in-flight roll can never be redirected under running nodes.
  """
  def authorize_rolling_replacement(target_id, identity) when is_map(identity) do
    with {:ok, authority} <- validate_rolling_authority(identity) do
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = rolling_authority_target(target_id, authority["sha"])
          details = target.details || %{}

          target
          |> Target.changeset(%{
            details:
              Map.put(details, "rolling_authority", published_authority(details, authority))
          })
          |> Repo.update!()
        end)
      end)
    end
  end

  def authorize_rolling_replacement(_target_id, _identity),
    do: {:error, :invalid_rolling_authority}

  @doc """
  Record one node's exact booted identity under the active rolling authority.

  The coordinator records each node as it rejoins. Settlement to `live`
  requires an exact-identity observation for every expected node, so this is
  the durable evidence that the whole fleet runs the authorized image. A
  rolled-back node records the previous identity instead, which keeps
  settlement refused and leaves the interrupted roll auditable.
  """
  def record_rolling_node(target_id, node, observation) when is_map(observation) do
    node = to_string(node)
    sha = result_value(observation, :sha)
    image_digest = result_value(observation, :image_digest)

    cond do
      not bounded_sha?(sha) ->
        {:error, :invalid_rolling_observation}

      not valid_image_digest?(image_digest) ->
        {:error, :invalid_rolling_observation}

      true ->
        :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
          Repo.transaction(fn ->
            target = rolling_authority_target(target_id, nil)
            details = target.details || %{}
            authority = active_authority(details) || Repo.rollback(:rolling_authority_missing)

            unless node in (authority["expected_nodes"] || []) do
              Repo.rollback(:rolling_node_not_expected)
            end

            observed =
              Map.put(authority["observed"] || %{}, node, %{
                "sha" => sha,
                "image_digest" => image_digest,
                "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
              })

            target
            |> Target.changeset(%{
              details:
                Map.put(details, "rolling_authority", Map.put(authority, "observed", observed))
            })
            |> Repo.update!()
          end)
        end)
    end
  end

  def record_rolling_node(_target_id, _node, _observation),
    do: {:error, :invalid_rolling_observation}

  @doc "The active rolling authority published on `repo`'s newest target, or nil."
  def rolling_authority(repo) do
    case current(repo) do
      %Target{status: "needs_rolling_replace", sha: sha, details: details} ->
        case active_authority(details || %{}) do
          %{"sha" => ^sha} = authority -> authority
          _other -> nil
        end

      _other ->
        nil
    end
  end

  @doc """
  Settle an operator-approved rolling replacement against its verified build.

  The rolling coordinator returns the bounded result passed to this function.
  Settlement succeeds only for the newest target, only after Forge classified
  it as `needs_rolling_replace`, and only when a complete build receipt exists.
  It is also bound to the published rolling authority: the result must carry
  the authorized SHA, image digest, previous pair, and exact expected node set,
  and a `live` settlement additionally requires that every expected node has
  recorded an observation of exactly that SHA and image digest. A roll that
  ended with any node on another identity refuses with
  `:rolling_nodes_not_converged` and leaves the target `needs_rolling_replace`.
  The target update and the second immutable deployment receipt commit in one
  database transaction. The original classification receipt remains intact.
  """
  def finish_rolling_replacement(target_id, rolling_result) when is_map(rolling_result) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          current_id =
            Target
            |> where([t], t.repo == ^target.repo)
            |> order_by([t], desc: t.inserted_at)
            |> limit(1)
            |> select([t], t.id)
            |> Repo.one()

          if current_id != target.id, do: Repo.rollback(:superseded_target)

          unless target.status == "needs_rolling_replace" do
            requested_status = result_value(rolling_result, :status) || "invalid"
            Repo.rollback({:invalid_transition, target.status, requested_status})
          end

          rolling =
            case validate_rolling_result(rolling_result, target.sha) do
              {:ok, rolling} -> rolling
              {:error, reason} -> Repo.rollback(reason)
            end

          case settlement_authority(target, rolling) do
            {:ok, _authority} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          build =
            BuildReceipt
            |> where([b], b.target_id == ^target.id and b.status == "complete")
            |> order_by([b], desc: b.inserted_at)
            |> limit(1)
            |> Repo.one()

          if is_nil(build), do: Repo.rollback(:complete_build_receipt_not_found)

          deployment_id = Ecto.UUID.generate()
          manifest_digest = manifest_digest(build.manifest)
          now = DateTime.utc_now()

          details = %{
            "artifact_digest" => build.artifact_digest,
            "deployment_id" => deployment_id,
            "image_digest" => rolling.image_digest,
            "manifest_digest" => manifest_digest,
            "previous_image_digest" => rolling.previous_image_digest,
            "previous_sha" => rolling.previous_sha,
            "rolling_error_code" => rolling.error_code,
            "rolling_node_results" => rolling.node_results,
            "rolling_recovery" => rolling.recovery
          }

          target =
            target
            |> Target.status_changeset(rolling.status, details)
            |> Repo.update!()

          receipt_attrs = %{
            artifact_digest: build.artifact_digest,
            completed_at: now,
            deployment_id: deployment_id,
            deployment_type: "rolling_replacement",
            error_code: rolling.error_code,
            expected_nodes: rolling.expected_nodes,
            manifest_digest: manifest_digest,
            modules: build.modules,
            node_results: rolling.node_results,
            nodes: Enum.map(rolling.expected_nodes, &"#{&1}=#{rolling.node_results[&1]}"),
            repo: target.repo,
            result: rolling.status,
            rollback_verified:
              rolling.status == "failed" and rolling.recovery == "last_known_good_restored",
            sha: target.sha,
            started_at:
              if(is_integer(rolling.duration_ms),
                do: DateTime.add(now, -rolling.duration_ms, :millisecond),
                else: now
              ),
            target_id: target.id
          }

          receipt =
            %DeployReceipt{}
            |> DeployReceipt.changeset(receipt_attrs)
            |> Repo.insert()
            |> case do
              {:ok, receipt} -> receipt
              {:error, changeset} -> Repo.rollback({:invalid_receipt, changeset})
            end

          %{target: target, receipt: receipt}
        end)
      end)

    with {:ok, %{target: target} = committed} <- result do
      broadcast_status(target)
      _ = record_deploy_evidence(committed)
      {:ok, committed}
    end
  end

  def finish_rolling_replacement(_target_id, _rolling_result),
    do: {:error, :invalid_rolling_result}

  defp rolling_authority_target(target_id, expected_sha) do
    target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

    current_id =
      Target
      |> where([t], t.repo == ^target.repo)
      |> order_by([t], desc: t.inserted_at)
      |> limit(1)
      |> select([t], t.id)
      |> Repo.one()

    if current_id != target.id, do: Repo.rollback(:superseded_target)

    unless target.status == "needs_rolling_replace" do
      Repo.rollback({:invalid_transition, target.status, "needs_rolling_replace"})
    end

    if is_binary(expected_sha) and target.sha != expected_sha do
      Repo.rollback(:rolling_authority_sha_mismatch)
    end

    target
  end

  # Publishing is idempotent for the identical identity, so an operator can
  # resume an interrupted roll without losing a single recorded observation.
  # Redirecting the roll is legal only before any node has been observed
  # under the published identity.
  defp published_authority(details, authority) do
    case active_authority(details) do
      nil ->
        Map.put(authority, "observed", %{})

      existing ->
        cond do
          rolling_identity(existing) == rolling_identity(authority) ->
            existing

          map_size(existing["observed"] || %{}) == 0 ->
            Map.put(authority, "observed", %{})

          true ->
            Repo.rollback(:rolling_authority_conflict)
        end
    end
  end

  defp active_authority(details) do
    case Map.get(details || %{}, "rolling_authority") do
      %{"schema" => @rolling_authority_schema} = authority -> authority
      _other -> nil
    end
  end

  defp rolling_identity(authority) do
    Map.take(authority, ~w(schema sha image_digest previous_sha previous_image_digest
      expected_nodes))
  end

  defp validate_rolling_authority(identity) do
    sha = result_value(identity, :sha)
    image_digest = result_value(identity, :image_digest)
    previous_sha = result_value(identity, :previous_sha)
    previous_image_digest = result_value(identity, :previous_image_digest)
    expected_nodes = result_value(identity, :expected_nodes)
    authorized_by = result_value(identity, :authorized_by)

    cond do
      not bounded_sha?(sha) ->
        {:error, :invalid_rolling_authority}

      not valid_sha?(previous_sha) ->
        {:error, :invalid_rolling_authority}

      not valid_image_digest?(image_digest) or not valid_image_digest?(previous_image_digest) ->
        {:error, :invalid_rolling_authority}

      image_digest == previous_image_digest ->
        {:error, :invalid_rolling_authority}

      not valid_node_list?(expected_nodes) ->
        {:error, :invalid_rolling_authority}

      not bounded_recovery?(authorized_by) ->
        {:error, :invalid_rolling_authority}

      true ->
        {:ok,
         %{
           "schema" => @rolling_authority_schema,
           "sha" => sha,
           "image_digest" => image_digest,
           "previous_sha" => previous_sha,
           "previous_image_digest" => previous_image_digest,
           "expected_nodes" => expected_nodes,
           "authorized_by" => authorized_by,
           "authorized_at" => DateTime.to_iso8601(DateTime.utc_now())
         }}
    end
  end

  # Settlement is bound to the published authority: the result must carry the
  # authorized identity and the exact expected node set, and `live` demands an
  # exact-identity observation from every one of those nodes.
  defp settlement_authority(target, rolling) do
    case active_authority(target.details || %{}) do
      nil ->
        {:error, :rolling_authority_missing}

      authority ->
        expected = authority["expected_nodes"] || []
        observed = authority["observed"] || %{}

        cond do
          authority["sha"] != target.sha or
            authority["image_digest"] != rolling.image_digest or
            authority["previous_sha"] != rolling.previous_sha or
              authority["previous_image_digest"] != rolling.previous_image_digest ->
            {:error, :rolling_authority_mismatch}

          expected != rolling.expected_nodes ->
            {:error, :rolling_node_set_mismatch}

          rolling.status == "live" and
              not Enum.all?(expected, &observed_identity?(observed, &1, authority)) ->
            {:error, :rolling_nodes_not_converged}

          true ->
            {:ok, authority}
        end
    end
  end

  defp observed_identity?(observed, node, authority) do
    case Map.get(observed, node) do
      %{"sha" => sha, "image_digest" => image_digest} ->
        sha == authority["sha"] and image_digest == authority["image_digest"]

      _missing ->
        false
    end
  end

  defp valid_node_list?(nodes) when is_list(nodes) and length(nodes) in 1..100 do
    Enum.all?(nodes, &(is_binary(&1) and byte_size(&1) in 1..255)) and
      nodes == Enum.sort(nodes) and length(nodes) == length(Enum.uniq(nodes))
  end

  defp valid_node_list?(_nodes), do: false

  defp bounded_sha?(value) when is_binary(value), do: byte_size(value) in 1..64
  defp bounded_sha?(_value), do: false

  defp validate_relup_result(result, target_sha) do
    schema = result_value(result, :schema)
    sha = result_value(result, :sha)
    from_revision = result_value(result, :from_revision)
    artifact_digest = result_value(result, :artifact_digest)
    package_manifest_digest = result_value(result, :package_manifest_digest)
    from_version = result_value(result, :from_version)
    to_version = result_value(result, :to_version)
    status = result_value(result, :status)
    node_results = result_value(result, :node_results)
    error_code = result_value(result, :error_code)
    duration_ms = result_value(result, :duration_ms)

    cond do
      schema != "openagents.relup-deployment.v1" ->
        {:error, :invalid_relup_result}

      sha != target_sha ->
        {:error, :relup_sha_mismatch}

      not valid_sha?(from_revision) ->
        {:error, :invalid_relup_result}

      not valid_digest?(artifact_digest) or not valid_digest?(package_manifest_digest) ->
        {:error, :invalid_relup_result}

      not valid_version?(from_version) or not valid_version?(to_version) or
          from_version == to_version ->
        {:error, :invalid_relup_result}

      status not in ~w(live failed) ->
        {:error, :invalid_relup_result}

      not valid_node_results?(node_results) ->
        {:error, :invalid_relup_result}

      not valid_duration?(duration_ms) ->
        {:error, :invalid_relup_result}

      status == "live" and
          (Enum.any?(node_results, fn {_node, node_status} -> node_status != "permanent" end) or
             not is_nil(error_code)) ->
        {:error, :invalid_relup_result}

      status == "failed" and not bounded_error?(error_code) ->
        {:error, :invalid_relup_result}

      true ->
        {:ok,
         %{
           artifact_digest: artifact_digest,
           duration_ms: duration_ms,
           error_code: error_code,
           expected_nodes: node_results |> Map.keys() |> Enum.sort(),
           from_revision: from_revision,
           from_version: from_version,
           node_results: node_results,
           package_manifest_digest: package_manifest_digest,
           status: status,
           to_version: to_version
         }}
    end
  end

  defp validate_rolling_result(result, target_sha) do
    schema = result_value(result, :schema)
    sha = result_value(result, :sha)
    previous_sha = result_value(result, :previous_sha)
    image_digest = result_value(result, :image_digest)
    previous_image_digest = result_value(result, :previous_image_digest)
    status = result_value(result, :status)
    node_results = result_value(result, :node_results)
    error_code = result_value(result, :error_code)
    recovery = result_value(result, :recovery)
    duration_ms = result_value(result, :duration_ms)

    cond do
      schema != "openagents.rolling-replacement.v1" ->
        {:error, :invalid_rolling_result}

      sha != target_sha ->
        {:error, :rolling_sha_mismatch}

      not valid_sha?(previous_sha) ->
        {:error, :invalid_rolling_result}

      not valid_image_digest?(image_digest) or not valid_image_digest?(previous_image_digest) ->
        {:error, :invalid_rolling_result}

      status not in ~w(live failed) ->
        {:error, :invalid_rolling_result}

      not valid_node_results?(node_results) ->
        {:error, :invalid_rolling_result}

      not (is_nil(duration_ms) or valid_duration?(duration_ms)) ->
        {:error, :invalid_rolling_result}

      status == "live" and
          (Enum.any?(node_results, fn {_node, node_status} -> node_status != "ready" end) or
             not is_nil(error_code) or not is_nil(recovery)) ->
        {:error, :invalid_rolling_result}

      status == "failed" and not bounded_error?(error_code) ->
        {:error, :invalid_rolling_result}

      status == "failed" and not bounded_recovery?(recovery) ->
        {:error, :invalid_rolling_result}

      true ->
        {:ok,
         %{
           duration_ms: duration_ms,
           error_code: error_code,
           expected_nodes: node_results |> Map.keys() |> Enum.sort(),
           image_digest: image_digest,
           node_results: node_results,
           previous_image_digest: previous_image_digest,
           previous_sha: previous_sha,
           recovery: recovery,
           status: status
         }}
    end
  end

  defp result_value(result, key), do: Map.get(result, key, Map.get(result, to_string(key)))

  defp valid_sha?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
  defp valid_sha?(_value), do: false

  defp valid_digest?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_digest?(_value), do: false

  defp valid_version?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/, value)

  defp valid_version?(_value), do: false

  defp valid_duration?(value), do: is_integer(value) and value in 0..86_400_000

  defp valid_image_digest?(value) when is_binary(value),
    do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp valid_image_digest?(_value), do: false

  defp valid_node_results?(results) when is_map(results) and map_size(results) in 1..100 do
    Enum.all?(results, fn {node, status} ->
      is_binary(node) and byte_size(node) in 1..255 and is_binary(status) and
        byte_size(status) in 1..255
    end)
  end

  defp valid_node_results?(_results), do: false

  defp bounded_error?(value) when is_binary(value),
    do: byte_size(value) in 1..128 and Regex.match?(~r/\A[a-z0-9_]+\z/, value)

  defp bounded_error?(_value), do: false

  defp bounded_recovery?(value) when is_binary(value), do: byte_size(value) in 1..255
  defp bounded_recovery?(_value), do: false

  defp manifest_digest(manifest) do
    manifest
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp bounded_details(details) do
    details
    |> Enum.map(fn {key, value} -> {to_string(key), bound_value(value)} end)
    |> Map.new()
  end

  defp bound_value(value) when is_binary(value), do: String.slice(value, 0, 8_192)
  defp bound_value(value) when is_list(value), do: Enum.take(value, 100)
  defp bound_value(value), do: value

  defp with_commit_store(repo, sha, store) do
    case store.(repo, sha) do
      :ok -> :ok
      :error -> {:error, :unknown_sha}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_sha_format(sha) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, sha), do: :ok, else: {:error, :invalid_sha}
  end

  defp validate_deployable_repo(repo) do
    owner = Application.get_env(:openagents, :forge_url_owner, "OpenAgentsInc")

    deployable? =
      Enum.any?(OpenAgents.Forge.Repos.allowed_repos(), fn allowed ->
        repo == allowed or repo == "#{owner}/#{allowed}"
      end)

    if deployable?,
      do: :ok,
      else: {:error, :repository_not_deployable}
  end

  # The promotable set is exactly what the WAL-backed repo contains.
  defp commit_exists_store(repo, sha) do
    if commit_exists?(repo, sha), do: :ok, else: {:error, :unknown_sha}
  end

  defp commit_exists?(repo, sha) do
    storage_key = Pushes.mirror_storage_key(repo)
    OpenAgents.Forge.Sync.ensure_fresh(storage_key)
    path = OpenAgents.Forge.Repos.bare_path(storage_key)

    case OpenAgents.Forge.Repos.git(path, ["cat-file", "-e", sha <> "^{commit}"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp broadcast_promotion(%Target{} = target) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:target",
      {:forge_target, %{repo: target.repo, sha: target.sha, target_id: target.id}}
    )
  end

  # Every successful status advance is announced (additive to the settled
  # contract, flagged on #126): the public status page renders the pipeline
  # sweeping promoted→building→built→deploying→live as it happens.
  defp broadcast_status(%Target{} = target) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:target",
      {:forge_target_status,
       %{repo: target.repo, sha: target.sha, target_id: target.id, status: target.status}}
    )
  end

  # The deployment receipt binds the exact commit it shipped. Recording the
  # edge here, right after the transaction that made the receipt immutable,
  # is what keeps an issue's deployment evidence out of a window scan.
  defp record_deploy_evidence(%{receipt: %DeployReceipt{} = receipt}),
    do: OpenAgents.Issues.Evidence.record_deploy(receipt)

  defp record_deploy_evidence(_committed), do: []
end
