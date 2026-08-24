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

  @doc """
  Discard the local bare-repository projection and re-materialize it from the
  WAL, from sequence zero.

  Use this when the projection is *wrong* rather than merely behind, where
  `ensure_fresh/1` and `replay_missing/3` would trust its existing state. It
  builds the whole repository in a sibling directory, proves every ref tip
  resolves, and only then swaps it in place, so readers never see a partial
  projection. Returns `:ok` on success and a typed error when the WAL cannot
  produce a servable projection. Takes no mirror input; `EXIT-003` holds the
  authority boundary.
  """
  def rebuild(repo, default_branch \\ "main") do
    synchronize(repo, fn ->
      case WAL.read_index(repo) do
        {:error, :not_found} -> :ok
        {:ok, _generation, index} -> rebuild_at_sibling!(repo, index, default_branch)
        {:error, reason} -> raise_sync(repo, :read_wal, reason)
      end
    end)
  end

  # Reentrant: `:global` locks are not reference counted, so a nested
  # `:global.trans` on the same id releases the lock when the inner call
  # exits (for example `ensure_fresh/2` inside a locked write). The process
  # dictionary marks the lock as held so nested calls run inline.
  @doc false
  def with_repo_lock(repo, function) when is_function(function, 0) do
    held_key = {__MODULE__, :repo_lock, repo}

    if Process.get(held_key) do
      function.()
    else
      lock_id = {{__MODULE__, repo}, self()}

      locked = fn ->
        Process.put(held_key, true)

        try do
          function.()
        after
          Process.delete(held_key)
        end
      end

      case :global.trans(lock_id, locked, [node()]) do
        {:aborted, reason} -> raise_sync(repo, :acquire_lock, reason)
        result -> result
      end
    end
  end

  defp do_replay_missing(repo, index, default_branch) do
    path = Repos.ensure_repo!(repo, default_branch)
    applied = Repos.applied_seq_at(path)

    case replay_entries(repo, path, index, applied) do
      :ok ->
        rebuild_if_objects_missing!(repo, index, default_branch)

      {:error, reason} ->
        # An entry that will not materialize incrementally is not fatal on
        # its own: the WAL still holds every entry, so rebuild from seq 0
        # (#96). Only a rebuild that also cannot materialize fails closed.
        Logger.warning(
          "forge_sync_cache_rebuild repo=#{repo} code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        rebuild_at_sibling!(repo, index, default_branch)
    end

    path = Repos.bare_path(repo)
    converge_refs(path, WAL.refs(index))
    Repos.set_default_branch_at!(path, default_branch)
    ensure_servable_graft(repo, path, index)
    :ok
  end

  # A clone walks from every ref into its ancestors, so a projection holding a
  # commit whose parents it does not hold cannot be cloned at all: git
  # `upload-pack` aborts the whole transfer rather than serving a truncated
  # history. The `shallow` file is what stops that walk, and it is the only
  # thing that does.
  #
  # A WAL entry states a boundary only when it carries a `shallow` key
  # (`REPOSITORY-003`). Entries written before that key existed carry none, so
  # a repository seeded from a shallow fetch — this forge's own among them —
  # projects onto disk ungrafted and refuses every full clone while every ref
  # tip still resolves. Every tip-shaped check therefore stays green, which is
  # how #179 survived to be found by someone cloning.
  #
  # The boundary is derived from the objects the projection actually holds
  # rather than only from what an entry remembered to record: a commit whose
  # parent is absent *is* a boundary, whatever the log says.
  #
  # Derived boundaries are added to the recorded ones rather than replacing
  # them, and that union is defensive rather than proven. A recorded boundary
  # is by definition a commit whose parent is absent, so the derivation finds
  # every recorded boundary any ref reaches, and removing the union reddens
  # nothing. It is kept for the boundary no ref reaches — which git prunes on
  # its own — so nothing here claims more than the derivation proves.
  #
  # Gated on the applied sequence so a current cache pays nothing. A cache
  # whose marker is absent is checked once, which is what repairs a projection
  # damaged before this existed.
  defp ensure_servable_graft(repo, path, index) do
    seq = WAL.next_seq(index) - 1

    if Repos.graft_seq_at(path) == seq do
      :ok
    else
      repair_graft(repo, path)
      Repos.record_graft_seq_at!(path, seq)
    end
  end

  defp repair_graft(repo, path) do
    unless servable?(path) do
      case derived_boundaries(path) do
        [] ->
          # Unwalkable and no boundary derivable: the repository is missing
          # objects a graft cannot excuse. Left alone rather than papered
          # over, and reported by `OpenAgents.Forge.Verification`.
          Logger.warning("forge_sync_graft_underivable repo=#{repo}")

        derived ->
          boundaries = Enum.sort(Enum.uniq(recorded_boundaries(path) ++ derived))
          Logger.warning("forge_sync_graft_repaired repo=#{repo} count=#{length(boundaries)}")
          write_shallow_boundaries(path, boundaries)
      end
    end
  end

  # The same walk `upload-pack` performs, with its output discarded: `--quiet`
  # keeps a large repository's object list out of the BEAM while still failing
  # on the first object the walk cannot read.
  defp servable?(path) do
    match?({_output, 0}, Repos.git(path, ["rev-list", "--objects", "--quiet", "--all"]))
  end

  # `--missing=print` reports an unreadable object as `?<oid>` instead of
  # aborting, so one walk yields both the missing objects and the parent lists
  # naming them. A commit with a missing parent is a boundary.
  defp derived_boundaries(path) do
    case Repos.git(path, ["rev-list", "--all", "--parents", "--missing=print"]) do
      {output, 0} -> boundaries_from(output)
      {_output, _status} -> []
    end
  end

  defp boundaries_from(output) do
    lines = String.split(output, "\n", trim: true)

    missing =
      for "?" <> object <- lines,
          into: MapSet.new(),
          do: object |> String.split(" ", parts: 2) |> hd()

    for line <- lines,
        not String.starts_with?(line, "?"),
        [commit | parents] = String.split(line, " ", trim: true),
        Enum.any?(parents, &MapSet.member?(missing, &1)),
        uniq: true,
        do: commit
  end

  defp recorded_boundaries(path) do
    case File.read(Path.join(path, "shallow")) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, _absent} -> []
    end
  end

  # Replay every entry the repository at `path` has not applied, threading
  # each entry's recorded post-state refs into the next one so an entry is
  # always applied against exactly the ref state its client saw.
  defp replay_entries(repo, path, index, applied) do
    index
    |> WAL.entries()
    |> Enum.reduce_while(%{}, fn entry, previous_refs ->
      if entry["seq"] > applied do
        case apply_entry(repo, path, entry, previous_refs) do
          :ok -> {:cont, entry_refs(entry)}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, entry_refs(entry)}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _refs -> :ok
    end
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

      case replay_entries(repo, rebuild_path, index, -1) do
        :ok -> :ok
        {:error, reason} -> raise_sync(repo, :rebuild_entry, reason)
      end

      converge_refs(rebuild_path, WAL.refs(index))
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

  # Apply one WAL entry: materialize its objects, prove the objects it
  # introduced are present, then move the refs to the post-state the entry
  # recorded.
  #
  # The ref convergence is not cosmetic. `git bundle unbundle` writes objects
  # and no refs, a `ref_update` entry carries no payload at all, and
  # `git receive-pack` re-runs push *admission* policy — old-OID locks and
  # shallow-boundary checks — that was already decided when the push was
  # accepted. Replaying a request against the wrong ref state makes git
  # refuse it, and a refusal costs the entry's objects: receive-pack drops
  # its object quarantine when every command fails, and exits 0 while doing
  # so. Converging per entry means each entry replays against exactly the ref
  # state its client saw, which is the state the WAL recorded.
  defp apply_entry(repo, path, %{"seq" => seq, "object" => object} = entry, previous_refs) do
    with :ok <- materialize_entry(repo, path, seq, entry, object),
         :ok <- verify_entry_objects(path, seq, entry, previous_refs) do
      converge_refs(path, entry_refs(entry))
      Repos.record_applied_seq_at!(path, seq)
      :ok
    end
  end

  defp materialize_entry(repo, path, seq, entry, object) do
    case entry["format"] || "receive_pack" do
      "receive_pack" ->
        with {:ok, payload} <- WAL.get_entry(repo, object) do
          case run_receive_pack(path, payload) do
            {_output, 0} -> :ok
            {_output, status} -> {:error, {:receive_pack_failed, seq, status}}
          end
        end

      "git_bundle" ->
        unbundle_entry(repo, path, object, entry)

      "empty_import" ->
        :ok

      # A batch ref update that introduced no new objects
      # (`OpenAgents.Forge.GitPlane.batch_update_refs/3`); its refs converge
      # from the entry.
      "ref_update" ->
        :ok
    end
  end

  # `git receive-pack` exits 0 even when it rejects every ref update, so an
  # entry's own exit status proves nothing. Prove the outcome instead: every
  # object this entry introduced must exist before its refs move. Only the
  # object IDs the entry adds are checked, because the ones it carries over
  # were proven when their own entry applied.
  defp verify_entry_objects(path, seq, entry, previous_refs) do
    known = previous_refs |> Map.values() |> MapSet.new()

    missing =
      entry
      |> entry_refs()
      |> Map.values()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.reject(fn sha ->
        match?({_output, 0}, Repos.git(path, ["cat-file", "-e", sha]))
      end)

    if missing == [], do: :ok, else: {:error, {:missing_ref_object, seq, missing}}
  end

  defp entry_refs(entry) do
    case Map.get(entry, "refs") do
      refs when is_map(refs) -> refs
      _absent -> %{}
    end
  end

  # The WAL is the ref authority; this makes the repository say so. Also used
  # once at the end of a replay so an empty index deletes stale local refs.
  defp converge_refs(path, target) do
    if Repos.refs_at(path) != target do
      Repos.set_refs_at!(path, target)
    end
  end

  defp unbundle_entry(repo, path, object, entry) do
    temporary_path =
      Path.join(
        Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!()),
        "openagents-import-#{System.unique_integer([:positive, :monotonic])}.bundle"
      )

    try do
      with :ok <- WAL.get_entry_file(repo, object, temporary_path),
           :ok <- File.chmod(temporary_path, 0o600) do
        case Repos.git(path, ["bundle", "unbundle", temporary_path]) do
          {_output, 0} -> write_shallow_boundaries(path, recorded_shallow(entry))
          {_output, _status} -> raise "repository bundle could not be materialized"
        end
      end
    after
      File.rm(temporary_path)
    end
  end

  # An import records the shallow boundaries its `--depth` fetch produced,
  # including an explicit empty list for a complete clone. Every other bundle
  # entry — a `GitPlane.batch_update_refs/3` batch, for instance — records no
  # boundary key at all and therefore says nothing about the graft. Treating
  # that silence as "no boundaries" ungrafts a shallow repository mid-replay,
  # after which git tries to walk past the boundary and every later entry
  # fails on a parent the WAL never held.
  defp recorded_shallow(entry) do
    case Map.fetch(entry, "shallow") do
      {:ok, boundaries} when is_list(boundaries) -> boundaries
      _unrecorded -> :unrecorded
    end
  end

  defp write_shallow_boundaries(_path, :unrecorded), do: :ok

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
