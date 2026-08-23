defmodule OpenAgents.Forge.Sync do
  @moduledoc """
  Cache freshness against the WAL: the bare repo on disk is a projection of
  the WAL, never authority. `ensure_fresh/1` compares the repo's applied WAL
  sequence to the index and replays any missing entries (each entry is the
  raw `receive-pack --stateless-rpc` request that produced it, so replay is
  exact). A deleted repo re-materializes from seq 0 the same way.
  """

  require Logger

  alias OpenAgents.Cluster
  alias OpenAgents.Forge.{CacheReadiness, GitHTTP, Repos, SyncError, WAL}

  @default_cluster_warm_timeout_ms 10 * 60 * 1_000

  @doc """
  Bring the local bare repo up to the WAL.

  Returns `:ok` when the projection is current and a typed error when the WAL
  or cache cannot produce an authoritative projection. Callers must not turn a
  synchronization error into a repository or object `404`.
  """
  def ensure_fresh(repo, default_branch \\ "main") do
    synchronize(repo, fn ->
      case WAL.read_index(repo) do
        {:error, :not_found} -> :ok
        {:ok, _generation, index} -> do_replay_missing(repo, index, default_branch)
        {:error, reason} -> raise_sync(repo, :read_wal, reason)
      end
    end)
  end

  @doc "Bring the local bare repo up to the WAL or raise a `503`-typed error."
  def ensure_fresh!(repo, default_branch \\ "main") do
    case ensure_fresh(repo, default_branch) do
      :ok -> :ok
      {:error, %SyncError{} = error} -> raise error
    end
  end

  @doc "Bring every connected node's disposable bare-repository cache up to date."
  def ensure_cluster_fresh(repo, default_branch \\ "main", options \\ []) do
    members = Keyword.get(options, :members, &Cluster.members/0).() |> Enum.uniq()
    rpc = Keyword.get(options, :rpc, &:erpc.call/5)

    timeout_ms =
      Keyword.get(
        options,
        :timeout_ms,
        Application.get_env(
          :openagents,
          :repository_cluster_warm_timeout_ms,
          @default_cluster_warm_timeout_ms
        )
      )

    members
    |> Task.async_stream(
      fn target -> warm_node(target, repo, default_branch, rpc, timeout_ms) end,
      ordered: false,
      timeout: timeout_ms + 1_000,
      on_timeout: :kill_task,
      max_concurrency: max(1, length(members))
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, reason}}
    end)
  end

  @doc "Replay WAL entries the local repo has not applied. Used by reads and boot."
  def replay_missing(repo, index, default_branch \\ "main") do
    synchronize(repo, fn -> do_replay_missing(repo, index, default_branch) end)
  end

  @doc false
  def with_repo_lock(repo, function) when is_function(function, 0) do
    lock_id = {{__MODULE__, repo}, self()}

    case :global.trans(lock_id, function, [node()]) do
      {:aborted, reason} -> raise_sync(repo, :acquire_lock, reason)
      result -> result
    end
  end

  defp do_replay_missing(repo, index, default_branch) do
    path = Repos.ensure_repo!(repo, default_branch)
    applied = Repos.applied_seq_at(path)

    index
    |> WAL.entries()
    |> Enum.filter(fn entry -> entry["seq"] > applied end)
    |> Enum.each(fn entry -> apply_entry!(repo, path, entry) end)

    rebuild_if_objects_missing!(repo, index, default_branch)
    path = Repos.bare_path(repo)
    converge_refs(path, index)
    Repos.set_default_branch_at!(path, default_branch)
    :ok
  end

  defp rebuild_if_objects_missing!(repo, index, default_branch) do
    unless refs_materialized?(repo, index) do
      Logger.warning("forge_sync_cache_rebuild repo=#{repo} code=missing_ref_object")
      rebuild_at_sibling!(repo, index, default_branch)
    end
  end

  defp rebuild_at_sibling!(repo, index, default_branch) do
    live_path = Repos.bare_path(repo)
    suffix = System.unique_integer([:positive, :monotonic])
    rebuild_path = live_path <> ".rebuild-#{suffix}"
    previous_path = live_path <> ".previous-#{suffix}"

    try do
      Repos.ensure_repo_at!(rebuild_path, default_branch)

      index
      |> WAL.entries()
      |> Enum.each(fn entry -> apply_entry!(repo, rebuild_path, entry) end)

      converge_refs(rebuild_path, index)
      Repos.set_default_branch_at!(rebuild_path, default_branch)

      unless refs_materialized_at?(rebuild_path, index) do
        raise_sync(repo, :verify_rebuild, :missing_ref_object)
      end

      swap_rebuild!(repo, live_path, rebuild_path, previous_path)
    after
      File.rm_rf(rebuild_path)

      # Keep the previous cache if activation and restoration both fail. It is
      # the last complete local projection an operator can recover.
      if File.exists?(live_path), do: File.rm_rf(previous_path)
    end
  end

  defp swap_rebuild!(repo, live_path, rebuild_path, previous_path) do
    live_exists? = File.exists?(live_path)

    if live_exists? do
      case File.rename(live_path, previous_path) do
        :ok -> :ok
        {:error, reason} -> raise_sync(repo, :stage_previous_cache, reason)
      end
    end

    case File.rename(rebuild_path, live_path) do
      :ok ->
        :ok

      {:error, reason} ->
        if live_exists?, do: File.rename(previous_path, live_path)
        raise_sync(repo, :activate_rebuild, reason)
    end
  end

  defp refs_materialized?(repo, index) do
    refs_materialized_at?(Repos.bare_path(repo), index)
  end

  defp refs_materialized_at?(path, index) do
    index
    |> WAL.refs()
    |> Map.values()
    |> Enum.uniq()
    |> Enum.all?(fn sha ->
      match?({_output, 0}, Repos.git(path, ["cat-file", "-e", sha]))
    end)
  end

  defp apply_entry!(repo, path, %{"seq" => seq, "object" => object} = entry) do
    case entry["format"] || "receive_pack" do
      "receive_pack" ->
        {:ok, payload} = WAL.get_entry(repo, object)
        {_output, 0} = run_receive_pack(path, payload)

      "git_bundle" ->
        :ok = unbundle_entry(repo, path, object, entry["shallow"] || [])

      "empty_import" ->
        :ok
    end

    Repos.record_applied_seq_at!(path, seq)
  end

  # Replay is exact in the common case; converge_refs makes the final state
  # authoritative even if an individual replayed request was non-idempotent
  # (e.g. a non-fast-forward the original push forced).
  defp converge_refs(path, index) do
    target = WAL.refs(index)

    if Repos.refs_at(path) != target do
      Repos.set_refs_at!(path, target)
    end
  end

  defp unbundle_entry(repo, path, object, shallow_boundaries) do
    temporary_path =
      Path.join(
        Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!()),
        "openagents-import-#{System.unique_integer([:positive, :monotonic])}.bundle"
      )

    try do
      with :ok <- WAL.get_entry_file(repo, object, temporary_path),
           :ok <- File.chmod(temporary_path, 0o600) do
        case Repos.git(path, ["bundle", "unbundle", temporary_path]) do
          {_output, 0} -> write_shallow_boundaries(path, shallow_boundaries)
          {_output, _status} -> raise "repository bundle could not be materialized"
        end
      end
    after
      File.rm(temporary_path)
    end
  end

  defp write_shallow_boundaries(path, []) do
    shallow_path = Path.join(path, "shallow")

    case File.rm(shallow_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "remove", path: shallow_path
    end
  end

  defp write_shallow_boundaries(path, shallow_boundaries) do
    valid? =
      Enum.all?(shallow_boundaries, fn boundary ->
        is_binary(boundary) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, boundary)
      end)

    if valid? do
      File.write!(
        Path.join(path, "shallow"),
        Enum.join(shallow_boundaries, "\n") <> "\n"
      )

      :ok
    else
      raise "repository bundle has invalid shallow boundaries"
    end
  end

  defp run_receive_pack(path, payload) do
    GitHTTP.run_git_service("receive-pack", [path], payload, nil)
  end

  defp warm_node(target, repo, default_branch, _rpc, _timeout_ms) when target == node(),
    do: ensure_fresh(repo, default_branch)

  defp warm_node(target, repo, default_branch, rpc, timeout_ms) do
    case rpc.(target, __MODULE__, :ensure_fresh, [repo, default_branch], timeout_ms) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_cluster_warm_result}
    end
  rescue
    _error -> {:error, :cluster_warm_exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp synchronize(repo, function) do
    result = with_repo_lock(repo, function)
    CacheReadiness.mark_available(repo)
    result
  rescue
    error ->
      sync_error = normalize_error(repo, error)
      CacheReadiness.mark_unavailable(repo, sync_error.operation)

      Logger.error(
        "forge_sync_unavailable repo=#{repo} operation=#{sync_error.operation} " <>
          "code=#{OpenAgents.OperationalLog.code(sync_error.reason)} detail=#{inspect(sync_error.reason)}"
      )

      {:error, sync_error}
  catch
    kind, reason ->
      sync_error = %SyncError{repo: repo, operation: :materialize_cache, reason: {kind, reason}}
      CacheReadiness.mark_unavailable(repo, sync_error.operation)
      {:error, sync_error}
  end

  defp normalize_error(_repo, %SyncError{} = error), do: error

  defp normalize_error(repo, error) do
    %SyncError{repo: repo, operation: :materialize_cache, reason: error}
  end

  defp raise_sync(repo, operation, reason) do
    raise SyncError, repo: repo, operation: operation, reason: reason
  end
end
