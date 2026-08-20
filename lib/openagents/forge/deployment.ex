defmodule OpenAgents.Forge.Deployment do
  @moduledoc """
  Coordinates one all-or-rollback direct deployment across an expected fleet.

  The coordinator snapshots a healthy, revision-consistent membership set,
  prepares every node, applies and verifies one canary, applies and verifies
  the remaining nodes, rechecks exact membership between phases, and commits
  only after every expected participant reports success. Any error triggers an
  exact rollback on every participant that issued a token.
  """

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.DeploymentNode

  @default_timeout_ms 15_000

  @doc "Run through fleet commit, retaining tokens until `finalize/1`."
  def run(build, verified, artifact_bytes, opts \\ []) do
    deployment_id = Ecto.UUID.generate()
    manifest_digest = BuildArtifact.digest(BuildProtocol.canonical_json(verified.manifest))

    base = %{
      deployment_id: deployment_id,
      target_id: build.target_id,
      repo: build.repo,
      sha: build.sha,
      build_id: build.build_id,
      artifact_digest: verified.digest,
      manifest_digest: manifest_digest,
      started_at: DateTime.utc_now(),
      expected_nodes: [],
      canary: nil,
      tokens: %{},
      applied_nodes: MapSet.new(),
      node_results: %{}
    }

    result =
      with {:ok, session} <- snapshot_fleet(base, opts),
           {:ok, session} <- prepare_fleet(session, artifact_bytes, opts),
           :ok <- stable_membership(session, opts),
           {:ok, session} <- apply_canary(session, opts),
           {:ok, session} <- verify_canary(session, opts),
           :ok <- stable_membership(session, opts),
           {:ok, session} <- apply_remainder(session, opts),
           :ok <- stable_membership(session, opts),
           {:ok, session} <- verify_fleet(session, opts),
           :ok <- stable_membership(session, opts),
           {:ok, session} <- commit_fleet(session, opts),
           :ok <- stable_membership(session, opts) do
        {:ok, session}
      end

    case result do
      {:ok, session} ->
        {:ok, public_session(session)}

      {:error, reason, session} ->
        rollback_failure(session, reason, opts)
    end
  end

  @doc "Finalize every committed node and release it into external readiness."
  def finalize(session, opts \\ []) do
    results = token_fanout(session, :finalize, opts)

    if all_stage_ok?(results),
      do: :ok,
      else: {:error, {:finalize_failed, result_codes(results)}}
  end

  @doc "Roll back a committed-but-not-finalized fleet transaction."
  def rollback(session, opts \\ []) do
    results = token_fanout(session, :rollback, opts)

    if all_restored?(results),
      do: {:ok, Map.new(results, fn {node, _result} -> {to_string(node), "restored"} end)},
      else: {:error, result_codes(results)}
  end

  defp snapshot_fleet(session, opts) do
    nodes = members(opts)
    expected_size = Application.fetch_env!(:openagents, :forge_expected_fleet_size)

    cond do
      length(nodes) != expected_size ->
        {:error, {:fleet_size_mismatch, expected_size, length(nodes)}, session}

      nodes == [] ->
        {:error, :empty_fleet, session}

      true ->
        results = fanout(nodes, :deployment_health, [session.repo, session.target_id], opts)

        with true <- all_health_ready?(results) or {:error, :fleet_not_ready},
             true <- consistent_revisions?(results) or {:error, :fleet_revision_divergent} do
          canary = if Node.self() in nodes, do: Node.self(), else: hd(nodes)

          {:ok,
           %{
             session
             | expected_nodes: nodes,
               canary: canary,
               node_results: health_results(results)
           }}
        else
          {:error, reason} -> {:error, reason, session_with_results(session, results)}
        end
    end
  end

  defp prepare_fleet(session, artifact_bytes, opts) do
    expected_strings = Enum.map(session.expected_nodes, &to_string/1)

    request = %{
      artifact_bytes: artifact_bytes,
      artifact_digest: session.artifact_digest,
      build_id: session.build_id,
      deployment_id: session.deployment_id,
      expected_nodes: expected_strings,
      manifest_digest: session.manifest_digest,
      repo: session.repo,
      sha: session.sha,
      target_id: session.target_id
    }

    results = fanout(session.expected_nodes, :prepare, [request], opts)

    tokens =
      Enum.reduce(results, %{}, fn
        {node, {:ok, {:ok, %{"token" => token}}}}, acc -> Map.put(acc, node, token)
        {_node, _result}, acc -> acc
      end)

    session = %{
      session
      | tokens: tokens,
        node_results: merge_results(session, results, "prepared")
    }

    if map_size(tokens) == length(session.expected_nodes),
      do: {:ok, session},
      else: {:error, {:prepare_failed, result_codes(results)}, session}
  end

  defp apply_canary(session, opts) do
    case call_token(session, session.canary, :apply_candidate, opts) do
      {:ok, {:ok, %{"phase" => "applied"}}} ->
        {:ok, mark_applied(session, session.canary)}

      result ->
        {:error, {:canary_apply_failed, result_code(result)}, session}
    end
  end

  defp verify_canary(session, opts) do
    case call_token(session, session.canary, :verify_candidate, opts) do
      {:ok, {:ok, %{"deployment_ready" => true, "revision" => revision}}}
      when revision == session.sha ->
        {:ok, put_result(session, session.canary, "verified")}

      result ->
        {:error, {:canary_verify_failed, result_code(result)}, session}
    end
  end

  defp apply_remainder(session, opts) do
    nodes = Enum.reject(session.expected_nodes, &(&1 == session.canary))
    results = fanout_tokens(session, nodes, :apply_candidate, opts)

    applied =
      Enum.reduce(results, session.applied_nodes, fn
        {node, {:ok, {:ok, %{"phase" => "applied"}}}}, acc -> MapSet.put(acc, node)
        {_node, _result}, acc -> acc
      end)

    session = %{
      session
      | applied_nodes: applied,
        node_results: merge_results(session, results, "applied")
    }

    if Enum.all?(results, fn {_node, result} ->
         match?({:ok, {:ok, %{"phase" => "applied"}}}, result)
       end),
       do: {:ok, session},
       else: {:error, {:fleet_apply_failed, result_codes(results)}, session}
  end

  defp verify_fleet(session, opts) do
    results = fanout_tokens(session, session.expected_nodes, :verify_candidate, opts)

    verified? =
      Enum.all?(results, fn
        {_node, {:ok, {:ok, %{"deployment_ready" => true, "revision" => revision}}}} ->
          revision == session.sha

        _other ->
          false
      end)

    session = %{session | node_results: merge_results(session, results, "verified")}

    if verified?,
      do: {:ok, session},
      else: {:error, {:fleet_verify_failed, result_codes(results)}, session}
  end

  defp commit_fleet(session, opts) do
    results = fanout_tokens(session, session.expected_nodes, :commit, opts)
    session = %{session | node_results: merge_results(session, results, "committed")}

    if Enum.all?(results, fn {_node, result} ->
         match?({:ok, {:ok, %{"phase" => "committed"}}}, result)
       end),
       do: {:ok, session},
       else: {:error, {:fleet_commit_failed, result_codes(results)}, session}
  end

  defp stable_membership(session, opts) do
    current = members(opts)

    if current == session.expected_nodes,
      do: :ok,
      else:
        {:error, {:membership_changed, membership_delta(session.expected_nodes, current)},
         session}
  end

  defp rollback_failure(session, reason, opts) do
    results = token_fanout(session, :rollback, opts)
    restored? = all_restored?(results)

    node_results =
      Map.new(results, fn
        {node, {:ok, {:ok, %{"restored" => true}}}} -> {to_string(node), "restored"}
        {node, result} -> {to_string(node), "rollback_failed:" <> result_code(result)}
      end)

    {:error, failure_outcome(session, reason, restored?, node_results)}
  end

  defp failure_outcome(session, reason, restored?, node_results) do
    %{
      deployment_id: session.deployment_id,
      target_id: session.target_id,
      repo: session.repo,
      sha: session.sha,
      build_id: session.build_id,
      artifact_digest: session.artifact_digest,
      manifest_digest: session.manifest_digest,
      expected_nodes: Enum.map(session.expected_nodes, &to_string/1),
      canary: if(session.canary, do: to_string(session.canary), else: nil),
      nodes:
        node_results |> Enum.map(fn {node, status} -> "#{node}=#{status}" end) |> Enum.sort(),
      node_results: node_results,
      result:
        if(restored? and MapSet.size(session.applied_nodes) > 0, do: "reverted", else: "failed"),
      error_code: safe_code(reason),
      rollback_verified: restored?,
      started_at: session.started_at
    }
  end

  defp public_session(session) do
    %{
      deployment_id: session.deployment_id,
      target_id: session.target_id,
      repo: session.repo,
      sha: session.sha,
      build_id: session.build_id,
      artifact_digest: session.artifact_digest,
      manifest_digest: session.manifest_digest,
      expected_nodes: Enum.map(session.expected_nodes, &to_string/1),
      canary: to_string(session.canary),
      nodes: Enum.map(session.expected_nodes, &(to_string(&1) <> "=committed")),
      node_results: Map.new(session.expected_nodes, &{to_string(&1), "committed"}),
      result: "live",
      error_code: nil,
      rollback_verified: nil,
      started_at: session.started_at,
      tokens: session.tokens,
      internal_nodes: session.expected_nodes
    }
  end

  defp token_fanout(session, phase, opts) do
    nodes = Map.get(session, :internal_nodes, session.expected_nodes)
    fanout_tokens(session, nodes, phase, opts)
  end

  defp fanout_tokens(session, nodes, phase, opts) do
    Map.new(nodes, fn node -> {node, call_token(session, node, phase, opts)} end)
  end

  defp call_token(session, node, phase, opts) do
    token = Map.fetch!(session.tokens, node)
    rpc(node, phase, [session.deployment_id, token], opts)
  end

  defp fanout(nodes, function, arguments, opts) do
    nodes
    |> Task.async_stream(&{&1, rpc(&1, function, arguments, opts)},
      ordered: true,
      timeout: timeout_ms(opts) + 1_000,
      on_timeout: :kill_task,
      max_concurrency: max(length(nodes), 1)
    )
    |> Enum.zip(nodes)
    |> Map.new(fn
      {{:ok, {node, result}}, _expected} -> {node, result}
      {{:exit, reason}, node} -> {node, {:error, {:task_exit, reason}}}
    end)
  end

  defp rpc(node, function, arguments, opts) do
    timeout = timeout_ms(opts)

    try do
      result =
        if node == Node.self() do
          apply(DeploymentNode, function, arguments)
        else
          :erpc.call(node, DeploymentNode, function, arguments, timeout)
        end

      {:ok, result}
    rescue
      error -> {:error, {:exception, safe_code(error)}}
    catch
      :exit, reason -> {:error, {:exit, safe_code(reason)}}
      kind, reason -> {:error, {kind, safe_code(reason)}}
    end
  end

  defp members(opts) do
    provider = Keyword.get(opts, :members, fn -> [Node.self() | Node.list()] end)
    provider.() |> Enum.uniq() |> Enum.sort()
  end

  defp all_health_ready?(results) do
    Enum.all?(results, fn
      {_node, {:ok, %{"ready" => true}}} -> true
      _other -> false
    end)
  end

  defp consistent_revisions?(results) do
    revisions =
      Enum.map(results, fn
        {_node, {:ok, %{"revision" => revision}}} -> revision
        _other -> nil
      end)

    nil not in revisions and length(Enum.uniq(revisions)) == 1
  end

  defp health_results(results) do
    Map.new(results, fn
      {node, {:ok, %{"ready" => true}}} -> {to_string(node), "healthy"}
      {node, result} -> {to_string(node), "unhealthy:" <> result_code(result)}
    end)
  end

  defp all_stage_ok?(results) do
    Enum.all?(results, fn {_node, result} -> match?({:ok, {:ok, _response}}, result) end)
  end

  defp all_restored?(results) do
    results != %{} and
      Enum.all?(results, fn
        {_node, {:ok, {:ok, %{"restored" => true}}}} -> true
        _other -> false
      end)
  end

  defp mark_applied(session, node) do
    session
    |> Map.update!(:applied_nodes, &MapSet.put(&1, node))
    |> put_result(node, "applied")
  end

  defp put_result(session, node, result) do
    put_in(session, [:node_results, to_string(node)], result)
  end

  defp merge_results(session, results, success) do
    Enum.reduce(results, session.node_results, fn
      {node, {:ok, {:ok, _response}}}, acc -> Map.put(acc, to_string(node), success)
      {node, result}, acc -> Map.put(acc, to_string(node), result_code(result))
    end)
  end

  defp session_with_results(session, results),
    do: %{session | node_results: merge_results(session, results, "ok")}

  defp membership_delta(expected, current) do
    %{
      missing: Enum.map(expected -- current, &to_string/1),
      unexpected: Enum.map(current -- expected, &to_string/1)
    }
  end

  defp result_codes(results),
    do: Map.new(results, fn {node, result} -> {to_string(node), result_code(result)} end)

  defp result_code({:ok, {:ok, _response}}), do: "ok"
  defp result_code({:ok, {:error, reason}}), do: safe_code(reason)
  defp result_code({:error, reason}), do: safe_code(reason)
  defp result_code(other), do: safe_code(other)

  defp safe_code(reason), do: OpenAgents.OperationalLog.code(reason)

  defp timeout_ms(opts),
    do:
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(:openagents, :forge_deploy_timeout_ms, @default_timeout_ms)
      )
end
