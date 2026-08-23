defmodule OpenAgents.Forge.RollingReplacement do
  @moduledoc """
  Coordinates a readiness-gated, one-node-at-a-time immutable image rollout.

  The coordinator requires an exact-SHA local release-gate receipt, verifies
  remaining capacity and quorum after each drain, and never starts another
  replacement until the prior node has rejoined and passed all health checks.
  A failed replacement triggers a last-known-good image rollback and aborts the
  fleet sequence.

  Before the first node is replaced it publishes the authorized rolling
  identity onto the Forge target named by the request. That published record is
  what lets boot convergence admit a replacement node's image the moment it
  boots, so a roll needs no feature-flag change and no manual restart of
  `OpenAgents.Forge.BootConverge`. As each node rejoins on the exact SHA and
  image digest the coordinator records that observation against the same
  authority, and settlement to `live` refuses until every expected node has
  one. A rolled-back node records the previous identity instead, so an
  interrupted roll leaves a recoverable, auditable state rather than a target
  that can still be settled.
  """

  alias OpenAgents.Forge.GateReceipt
  alias OpenAgents.Forge.Targets

  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/
  @default_wait_attempts 120
  @default_wait_interval_ms 1_000

  @doc "Roll an immutable image across the exact expected node set."
  def run(request, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with :ok <- validate_request(request),
         {:ok, _receipt} <- gate_verify(request.sha, opts),
         {:ok, provider} <- provider(opts),
         :ok <- initial_membership(request, provider, opts),
         :ok <- publish_authority(request, opts) do
      request.expected_nodes
      |> replace_nodes(request, provider, opts, %{})
      |> put_duration(started)
    end
  end

  defp put_duration({verdict, result}, started) when is_map(result) do
    {verdict, Map.put(result, :duration_ms, System.monotonic_time(:millisecond) - started)}
  end

  defp replace_nodes([], request, _provider, _opts, results) do
    {:ok, public_result(request, "live", results, nil, nil)}
  end

  defp replace_nodes([node | remaining], request, provider, opts, results) do
    case replace_node(node, request, provider, opts) do
      {:ok, "ready"} ->
        replace_nodes(
          remaining,
          request,
          provider,
          opts,
          Map.put(results, to_string(node), "ready")
        )

      {:error, reason, recovery} ->
        failed_results = Map.put(results, to_string(node), safe_code(reason))

        {:error,
         public_result(
           request,
           "failed",
           failed_results,
           safe_code(reason),
           recovery
         )}
    end
  end

  defp replace_node(node, request, provider, opts) do
    remaining = Enum.reject(request.expected_nodes, &(&1 == node))
    context = context(request)

    case provider.remove_readiness(node, context) do
      :ok ->
        with :ok <- wait_for_drain(provider, node, context, opts),
             :ok <- verify_capacity(provider, remaining, request, context) do
          replace_drained_node(node, request, provider, context, opts)
        else
          {:error, reason} ->
            restore_admission(provider, node, context, reason)

          other ->
            restore_admission(provider, node, context, {:unexpected_provider_result, other})
        end

      {:error, reason} ->
        {:error, {:readiness_removal_failed, reason}, "readiness_unchanged"}

      other ->
        {:error, {:invalid_readiness_result, other}, "readiness_unchanged"}
    end
  end

  defp replace_drained_node(node, request, provider, context, opts) do
    with :ok <- provider.replace(node, request.image_digest, context),
         :ok <- wait_for_target(provider, node, request, context, opts),
         :ok <- exact_membership(request, provider, opts) do
      {:ok, "ready"}
    else
      {:error, reason} ->
        recover_node(provider, node, request, context, reason, opts)

      other ->
        recover_node(provider, node, request, context, {:unexpected_provider_result, other}, opts)
    end
  end

  defp restore_admission(provider, node, context, reason) do
    recovery =
      case provider.restore_readiness(node, context) do
        :ok -> "readiness_restored"
        {:error, restore_reason} -> "readiness_restore_failed:" <> safe_code(restore_reason)
        other -> "readiness_restore_failed:" <> safe_code(other)
      end

    {:error, reason, recovery}
  end

  defp recover_node(provider, node, request, context, reason, opts) do
    recovery =
      with :ok <- provider.rollback(node, request.previous_image_digest, context),
           :ok <- wait_for_previous(provider, node, request, context, opts) do
        record_rollback(request, opts, node)
      else
        {:error, recovery_reason} -> "rollback_failed:" <> safe_code(recovery_reason)
        other -> "rollback_failed:" <> safe_code(other)
      end

    {:error, reason, recovery}
  end

  defp wait_for_drain(provider, node, context, opts) do
    poll(opts, fn ->
      case provider.drain(node, context) do
        {:ok, 0} -> :ok
        {:ok, count} when is_integer(count) and count > 0 -> :retry
        {:error, reason} -> {:error, {:drain_failed, reason}}
        other -> {:error, {:invalid_drain_result, other}}
      end
    end)
  end

  defp verify_capacity(provider, remaining, request, context) do
    case provider.capacity(remaining, context) do
      {:ok, %{ready: ready, quorum: true}}
      when is_integer(ready) and ready >= request.minimum_ready ->
        :ok

      {:ok, %{quorum: false}} ->
        {:error, :quorum_lost_after_drain}

      {:ok, %{ready: ready}} when is_integer(ready) ->
        {:error, {:insufficient_capacity, ready, request.minimum_ready}}

      {:error, reason} ->
        {:error, {:capacity_check_failed, reason}}

      other ->
        {:error, {:invalid_capacity_result, other}}
    end
  end

  defp wait_for_target(provider, node, request, context, opts) do
    poll(opts, fn ->
      case provider.status(node, context) do
        {:ok,
         %{
           member: true,
           ready: true,
           boot_converged: true,
           database_ready: true,
           sha: sha,
           image_digest: digest
         }}
        when sha == request.sha and digest == request.image_digest ->
          record_node(request, opts, node, sha, digest)

        {:ok, _not_ready} ->
          :retry

        {:error, reason} ->
          {:error, {:rejoin_check_failed, reason}}

        other ->
          {:error, {:invalid_rejoin_result, other}}
      end
    end)
  end

  defp wait_for_previous(provider, node, request, context, opts) do
    poll(opts, fn ->
      case provider.status(node, context) do
        {:ok,
         %{
           member: true,
           ready: true,
           boot_converged: true,
           database_ready: true,
           sha: sha,
           image_digest: digest
         }}
        when sha == request.previous_sha and digest == request.previous_image_digest ->
          :ok

        {:ok, _not_ready} ->
          :retry

        {:error, reason} ->
          {:error, {:rollback_rejoin_check_failed, reason}}

        other ->
          {:error, {:invalid_rollback_rejoin_result, other}}
      end
    end)
  end

  # Published before the first replacement so a node booted into the new image
  # is already an authorized identity when its boot convergence first runs.
  defp publish_authority(request, opts) do
    case authority(opts).authorize_rolling_replacement(request.target_id, %{
           sha: request.sha,
           image_digest: request.image_digest,
           previous_sha: request.previous_sha,
           previous_image_digest: request.previous_image_digest,
           expected_nodes: Enum.sort(Enum.map(request.expected_nodes, &to_string/1)),
           authorized_by: Map.get(request, :authorized_by, "operator")
         }) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, {:rolling_authority_refused, reason}}
      other -> {:error, {:invalid_rolling_authority_result, other}}
    end
  end

  defp record_node(request, opts, node, sha, image_digest) do
    case authority(opts).record_rolling_node(request.target_id, to_string(node), %{
           sha: sha,
           image_digest: image_digest
         }) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, {:rolling_node_record_failed, reason}}
      other -> {:error, {:invalid_rolling_observation_result, other}}
    end
  end

  # The rollback itself succeeded; recording it is what keeps the interrupted
  # roll auditable, so an unrecorded rollback is reported as its own outcome
  # rather than silently passing as a verified one.
  defp record_rollback(request, opts, node) do
    case record_node(
           request,
           opts,
           node,
           request.previous_sha,
           request.previous_image_digest
         ) do
      :ok -> "last_known_good_restored"
      {:error, reason} -> "last_known_good_unrecorded:" <> safe_code(reason)
    end
  end

  defp authority(opts), do: Keyword.get(opts, :authority, Targets)

  defp poll(opts, function) do
    attempts = Keyword.get(opts, :wait_attempts, @default_wait_attempts)
    interval = Keyword.get(opts, :wait_interval_ms, @default_wait_interval_ms)
    do_poll(function, attempts, interval)
  end

  defp do_poll(_function, 0, _interval), do: {:error, :wait_timeout}

  defp do_poll(function, attempts, interval) do
    case function.() do
      :ok ->
        :ok

      :retry ->
        wait(interval)
        do_poll(function, attempts - 1, interval)

      {:error, _reason} = error ->
        error
    end
  end

  defp wait(0), do: :ok

  defp wait(milliseconds) do
    receive do
    after
      milliseconds -> :ok
    end
  end

  defp initial_membership(request, provider, opts),
    do: exact_membership(request, provider, opts)

  defp exact_membership(request, provider, opts) do
    if members(provider, opts) == request.expected_nodes,
      do: :ok,
      else: {:error, :fleet_membership_mismatch}
  end

  defp members(provider, opts) do
    Keyword.get(opts, :members, &provider.members/0).()
    |> Enum.sort()
  end

  defp provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} when is_atom(provider) -> {:ok, provider}
      _missing -> {:error, :rolling_provider_not_configured}
    end
  end

  defp gate_verify(sha, opts) do
    case Keyword.fetch(opts, :gate_verifier) do
      {:ok, verifier} -> verifier.(sha)
      :error -> GateReceipt.verify(sha, Keyword.get(opts, :gate_receipt_options, []))
    end
  end

  defp validate_request(request) when is_map(request) do
    nodes = Map.get(request, :expected_nodes)

    cond do
      not valid_target_id?(Map.get(request, :target_id)) ->
        {:error, :invalid_target_id}

      not Regex.match?(@sha_pattern, Map.get(request, :sha, "")) ->
        {:error, :invalid_git_sha}

      not Regex.match?(@sha_pattern, Map.get(request, :previous_sha, "")) ->
        {:error, :invalid_previous_git_sha}

      not Regex.match?(@digest_pattern, Map.get(request, :image_digest, "")) ->
        {:error, :invalid_image_digest}

      not Regex.match?(@digest_pattern, Map.get(request, :previous_image_digest, "")) ->
        {:error, :invalid_previous_image_digest}

      request.image_digest == request.previous_image_digest ->
        {:error, :image_digest_unchanged}

      not is_list(nodes) or nodes == [] ->
        {:error, :invalid_expected_nodes}

      nodes != Enum.sort(nodes) or length(nodes) != length(Enum.uniq(nodes)) ->
        {:error, :invalid_expected_nodes}

      Map.get(request, :expected_fleet_size) != length(nodes) ->
        {:error, :invalid_expected_fleet_size}

      not is_integer(Map.get(request, :minimum_ready)) ->
        {:error, :invalid_minimum_ready}

      request.minimum_ready < div(request.expected_fleet_size, 2) + 1 ->
        {:error, :minimum_ready_below_quorum}

      request.minimum_ready > request.expected_fleet_size - 1 ->
        {:error, :minimum_ready_exceeds_remaining_fleet}

      true ->
        :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp valid_target_id?(value) when is_binary(value),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp valid_target_id?(_value), do: false

  defp context(request) do
    %{
      sha: request.sha,
      previous_sha: request.previous_sha,
      image_digest: request.image_digest,
      previous_image_digest: request.previous_image_digest,
      expected_nodes: request.expected_nodes
    }
  end

  defp public_result(request, status, node_results, error_code, recovery) do
    %{
      schema: "openagents.rolling-replacement.v1",
      target_id: request.target_id,
      sha: request.sha,
      previous_sha: request.previous_sha,
      image_digest: request.image_digest,
      previous_image_digest: request.previous_image_digest,
      status: status,
      node_results: node_results,
      error_code: error_code,
      recovery: recovery
    }
  end

  defp safe_code(reason), do: OpenAgents.OperationalLog.code(reason)
end
