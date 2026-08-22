defmodule OpenAgents.Forge.RelupDeployment do
  @moduledoc """
  Upgrades an exact fleet one node at a time through a two-way OTP relup.

  The coordinator rechecks membership between nodes, makes a candidate
  permanent only after health and state verification, and installs the reverse
  relup when post-install health fails.
  """

  alias OpenAgents.Forge.GateReceipt
  alias OpenAgents.Forge.RelupNode

  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  # Same admission the per-node release-handler transaction enforces
  # (RelupNode): any concrete X.Y.Z[-+suffix] pair. The real gate for a
  # transition is the packaged appup on the node itself; check_install refuses
  # honestly when no relup exists between the two versions.
  @version_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
  @supported_state_versions [1, 2]
  @default_timeout_ms 120_000

  @doc "Deploy one two-way relup across the exact expected fleet."
  def run(request, opts \\ []) do
    with :ok <- validate_request(request),
         {:ok, _receipt} <- gate_verify(request.sha, opts),
         {:ok, nodes} <- snapshot_members(request, opts) do
      deploy_nodes(nodes, request, opts, %{}, [])
    end
  end

  defp deploy_nodes([], request, _opts, results, _completed) do
    {:ok, public_result(request, "live", results, nil)}
  end

  defp deploy_nodes([node | remaining], request, opts, results, completed) do
    with :ok <- stable_membership(request, opts) do
      case deploy_node(node, request, opts) do
        {:ok, result} ->
          case stable_membership(request, opts) do
            :ok ->
              deploy_nodes(
                remaining,
                request,
                opts,
                Map.put(results, to_string(node), result),
                [node | completed]
              )

            {:error, reason} ->
              fail_deployment(node, reason, [node | completed], request, opts, results)
          end

        {:error, reason} ->
          fail_deployment(node, reason, completed, request, opts, results)
      end
    else
      {:error, reason} ->
        fail_deployment(node, reason, completed, request, opts, results)
    end
  end

  defp fail_deployment(node, reason, rollback_nodes, request, opts, results) do
    {rollback_results, rollback_status} = rollback_completed(rollback_nodes, request, opts)

    failure =
      results
      |> Map.merge(rollback_results)
      |> Map.put(to_string(node), safe_code(reason))

    error_code =
      if rollback_status == :ok,
        do: safe_code(reason),
        else: "fleet_reverse_failed:" <> safe_code(reason)

    {:error, public_result(request, "failed", failure, error_code)}
  end

  defp rollback_completed(nodes, request, opts) do
    Enum.reduce(nodes, {%{}, :ok}, fn node, {results, status} ->
      case call(node, :reverse, [request], opts) do
        {:ok, _result} ->
          {Map.put(results, to_string(node), "reversed"), status}

        {:error, reason} ->
          {Map.put(results, to_string(node), "reverse_failed:" <> safe_code(reason)), :error}
      end
    end)
  end

  defp deploy_node(node, request, opts) do
    preinstall_steps = [:stage, :verify_stage, :unpack, :check_install]

    with :ok <- run_steps(node, preinstall_steps, request, opts),
         {:ok, _result} <- call(node, :install, [request], opts) do
      finish_installed_node(node, request, opts)
    end
  end

  defp finish_installed_node(node, request, opts) do
    with {:ok, _result} <- call(node, :verify, [request, :current], opts),
         {:ok, _result} <- call(node, :make_permanent, [request], opts),
         {:ok, _result} <- call(node, :verify, [request, :permanent], opts) do
      {:ok, "permanent"}
    else
      {:error, reason} -> reverse_after_failure(node, request, reason, opts)
    end
  end

  defp reverse_after_failure(node, request, reason, opts) do
    case call(node, :reverse, [request], opts) do
      {:ok, _result} ->
        {:error, {:node_reversed, safe_code(reason)}}

      {:error, reverse_reason} ->
        {:error, {:reverse_failed, safe_code(reason), safe_code(reverse_reason)}}
    end
  end

  defp run_steps(node, steps, request, opts) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case call(node, step, [request], opts) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {step, reason}}}
      end
    end)
  end

  defp snapshot_members(request, opts) do
    current = members(opts)

    cond do
      current != request.expected_nodes -> {:error, :fleet_membership_mismatch}
      length(current) != request.expected_fleet_size -> {:error, :fleet_size_mismatch}
      true -> {:ok, current}
    end
  end

  defp stable_membership(request, opts) do
    if members(opts) == request.expected_nodes, do: :ok, else: {:error, :membership_changed}
  end

  defp members(opts) do
    Keyword.get(opts, :members, &OpenAgents.Cluster.members/0).()
    |> Enum.sort()
  end

  defp call(node, function, arguments, opts) do
    rpc = Keyword.get(opts, :rpc, &default_rpc/5)

    case rpc.(node, RelupNode, function, arguments, timeout(opts)) do
      {:ok, _result} = success -> success
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_rpc_result, safe_code(other)}}
    end
  rescue
    error -> {:error, {:rpc_exception, safe_code(error)}}
  catch
    kind, reason -> {:error, {:rpc_exit, safe_code({kind, reason})}}
  end

  defp default_rpc(node, module, function, arguments, timeout) do
    if node == Node.self() do
      apply(module, function, arguments)
    else
      :erpc.call(node, module, function, arguments, timeout)
    end
  end

  defp gate_verify(sha, opts) do
    case Keyword.fetch(opts, :gate_verifier) do
      {:ok, verifier} -> verifier.(sha)
      :error -> GateReceipt.verify(sha, Keyword.get(opts, :gate_receipt_options, []))
    end
  end

  defp validate_request(request) when is_map(request) do
    from_version = Map.get(request, :from_version)
    to_version = Map.get(request, :to_version)

    cond do
      not Regex.match?(@sha_pattern, Map.get(request, :sha, "")) ->
        {:error, :invalid_git_sha}

      not Regex.match?(@sha_pattern, Map.get(request, :from_revision, "")) ->
        {:error, :invalid_from_git_sha}

      not Regex.match?(@digest_pattern, Map.get(request, :artifact_digest, "")) ->
        {:error, :invalid_artifact_digest}

      not Regex.match?(@digest_pattern, Map.get(request, :package_manifest_digest, "")) ->
        {:error, :invalid_package_manifest_digest}

      not is_binary(Map.get(request, :artifact_bytes)) ->
        {:error, :invalid_artifact}

      Map.get(request, :release_name) != "openagents" ->
        {:error, :invalid_release_name}

      not version?(from_version) ->
        {:error, :invalid_from_version}

      not version?(to_version) ->
        {:error, :invalid_to_version}

      from_version == to_version ->
        {:error, :degenerate_version_transition}

      Map.get(request, :from_state_version) not in @supported_state_versions ->
        {:error, :unsupported_from_state_version}

      Map.get(request, :to_state_version) not in @supported_state_versions ->
        {:error, :unsupported_to_state_version}

      Map.get(request, :to_state_version) < Map.get(request, :from_state_version) ->
        {:error, :state_version_regression}

      not is_list(Map.get(request, :expected_nodes)) ->
        {:error, :invalid_expected_nodes}

      Map.get(request, :expected_nodes) != Enum.sort(Map.get(request, :expected_nodes)) ->
        {:error, :unsorted_expected_nodes}

      Map.get(request, :expected_fleet_size) != length(Map.get(request, :expected_nodes)) ->
        {:error, :invalid_expected_fleet_size}

      true ->
        :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp version?(version), do: is_binary(version) and Regex.match?(@version_pattern, version)

  defp public_result(request, status, node_results, error_code) do
    %{
      schema: "openagents.relup-deployment.v1",
      sha: request.sha,
      from_revision: request.from_revision,
      artifact_digest: request.artifact_digest,
      package_manifest_digest: request.package_manifest_digest,
      from_version: request.from_version,
      to_version: request.to_version,
      status: status,
      node_results: node_results,
      error_code: error_code
    }
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
  defp safe_code(reason), do: OpenAgents.OperationalLog.code(reason)
end
