defmodule OpenAgents.Forge.GitPlane do
  @moduledoc """
  Git primitives a stack service composes (#46): ref resolution, ancestry
  checks, merge-base reads, tree-merge planning, boundary-based commit
  replay, and atomic multi-ref updates. Nothing here knows what a pull
  request is.

  Reads run against the bare repo cache after a WAL freshness check, the
  same way `OpenAgents.Forge.Browse` reads do. Writes go through
  `batch_update_refs/3`: every ref in the batch applies or none does, each
  update carries an expected old OID, and the WAL records one entry for the
  batch so cache convergence and mirrors see one transition.

  All git invocations are argv-only against `--git-dir`, per the
  `OpenAgents.Forge.Repos.git/3` discipline. Where git needs stdin
  (`update-ref --stdin`, `commit-tree`), the input rides a server-generated
  temp file exactly as `OpenAgents.Forge.GitHTTP.run_git_service/4` does.
  """

  require Logger

  alias OpenAgents.Forge.{Pushes, Repos, Sync, WAL}

  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @ref_pattern ~r|\Arefs/[A-Za-z0-9][A-Za-z0-9._/-]{0,200}\z|
  @segment_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @committer_name "OpenAgents Forge"
  @committer_email "forge@openagents.com"

  @typedoc "A full object ID: 40 (SHA-1) or 64 (SHA-256) lowercase hex characters."
  @type oid :: String.t()

  @typedoc """
  One ref update in a batch.

  `:expected_old` is the OID the ref must currently have, or `:absent` when
  the ref must not exist yet. `:new` is the target OID, or `:delete` to
  remove the ref.
  """
  @type ref_update :: %{
          ref: String.t(),
          expected_old: oid | :absent,
          new: oid | :delete
        }

  ## Reads

  @doc "Resolve a ref name or (short) OID to a full commit OID, after a freshness check."
  def resolve_commit(repo, ref) do
    with :ok <- check_rev(ref),
         :ok <- Sync.ensure_fresh(repo) do
      case git(repo, ["rev-parse", "--verify", "--quiet", "--end-of-options", ref <> "^{commit}"]) do
        {output, 0} -> {:ok, String.trim(output)}
        _other -> {:error, :not_found}
      end
    end
  end

  @doc "Whether `ancestor` is an ancestor of (or equal to) `descendant`."
  def ancestor?(repo, ancestor, descendant) do
    with :ok <- check_rev(ancestor),
         :ok <- check_rev(descendant),
         :ok <- Sync.ensure_fresh(repo) do
      case git(repo, ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant]) do
        {_output, 0} -> {:ok, true}
        {_output, 1} -> {:ok, false}
        _other -> {:error, :not_found}
      end
    end
  end

  @doc "The best common ancestor of two commits, or `{:error, :no_merge_base}`."
  def merge_base(repo, rev_a, rev_b) do
    with :ok <- check_rev(rev_a),
         :ok <- check_rev(rev_b),
         :ok <- Sync.ensure_fresh(repo) do
      case git(repo, ["merge-base", "--end-of-options", rev_a, rev_b]) do
        {output, 0} -> {:ok, String.trim(output)}
        {_output, 1} -> {:error, :no_merge_base}
        _other -> {:error, :not_found}
      end
    end
  end

  ## Tree-merge planning

  @doc """
  Plan a tree merge with `git merge-tree --write-tree` without touching refs.

  Returns `{:ok, %{tree: oid}}` for a clean merge. A conflicted merge
  returns `{:conflict, %{tree: oid, paths: [...], files: [...], messages: [...]}}`
  where `files` carries the structured `{mode, oid, stage, path}` rows git
  reports for each conflicted path. Pass `merge_base: oid` to pin the base
  instead of letting git compute one.
  """
  def merge_tree(repo, ours, theirs, opts \\ []) do
    with :ok <- check_rev(ours),
         :ok <- check_rev(theirs),
         :ok <- check_optional_rev(opts[:merge_base]),
         :ok <- Sync.ensure_fresh(repo) do
      merge_tree_from_cache(Repos.bare_path(repo), ours, theirs, opts)
    end
  end

  defp merge_tree_from_cache(path, ours, theirs, opts) do
    base_args =
      case opts[:merge_base] do
        nil -> []
        base -> ["--merge-base=" <> base]
      end

    args =
      ["merge-tree", "--write-tree", "--messages"] ++
        base_args ++ ["--end-of-options", ours, theirs]

    case Repos.git(path, args) do
      {output, 0} ->
        {:ok, %{tree: output |> String.split("\n", parts: 2) |> hd() |> String.trim()}}

      {output, 1} ->
        {:conflict, parse_conflicted_merge(output)}

      _other ->
        {:error, :merge_tree_failed}
    end
  end

  defp parse_conflicted_merge(output) do
    [tree | rest] = String.split(output, "\n")
    {file_lines, message_lines} = Enum.split_while(rest, &(&1 != ""))

    files =
      Enum.flat_map(file_lines, fn line ->
        with [meta, file_path] <- String.split(line, "\t", parts: 2),
             [mode, oid, stage] <- String.split(meta, " ", trim: true) do
          [%{mode: mode, oid: oid, stage: stage, path: file_path}]
        else
          _other -> []
        end
      end)

    %{
      tree: String.trim(tree),
      files: files,
      paths: files |> Enum.map(& &1.path) |> Enum.uniq(),
      messages: message_lines |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
    }
  end

  ## Commit replay

  @doc """
  Replay commits with `git rebase --onto` boundary semantics: only commits
  reachable from `old_head` but not from `boundary` replay, in order, onto
  `onto`.

  Returns `{:ok, %{new_head: oid, replayed: [%{old: oid, new: oid}]}}` — an
  empty range returns `onto` unchanged. A conflicting commit returns
  `{:conflict, %{commit: oid, onto: oid, paths: [...], files: [...], messages: [...],
  replayed: [...]}}` with the steps that already succeeded, so a caller can
  persist the conflict state. New commits are created as unreachable objects;
  refs move only through `batch_update_refs/3`.

  Author identity and message are preserved from each original commit; the
  committer is the forge service identity, and the replayed commits are
  unsigned (the commit-signature policy of `docs/stacked-prs.md` section 12.5).
  Merge commits and root commits in the range are rejected.
  """
  def replay(repo, boundary, old_head, onto) do
    with :ok <- check_oid(boundary),
         :ok <- check_oid(old_head),
         :ok <- check_oid(onto),
         :ok <- Sync.ensure_fresh(repo) do
      path = Repos.bare_path(repo)

      with {:ok, commits} <- commits_after_boundary(path, boundary, old_head) do
        replay_each(path, commits, onto, [])
      end
    end
  end

  defp commits_after_boundary(path, boundary, old_head) do
    args = [
      "rev-list",
      "--reverse",
      "--topo-order",
      "--end-of-options",
      old_head,
      "^" <> boundary
    ]

    case Repos.git(path, args) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      _other -> {:error, :not_found}
    end
  end

  defp replay_each(_path, [], onto, replayed),
    do: {:ok, %{new_head: onto, replayed: Enum.reverse(replayed)}}

  defp replay_each(path, [commit | rest], onto, replayed) do
    with {:ok, parent} <- sole_parent(path, commit),
         {:ok, tree} <- replay_tree(path, commit, parent, onto, replayed),
         {:ok, new_commit} <- commit_replayed_tree(path, commit, tree, onto) do
      replay_each(path, rest, new_commit, [%{old: commit, new: new_commit} | replayed])
    end
  end

  defp sole_parent(path, commit) do
    case Repos.git(path, ["show", "-s", "--format=%P", "--end-of-options", commit]) do
      {output, 0} ->
        case String.split(output, " ", trim: true) |> Enum.map(&String.trim/1) do
          [parent] -> {:ok, parent}
          [] -> {:error, {:root_commit, commit}}
          _multiple -> {:error, {:merge_commit, commit}}
        end

      _other ->
        {:error, :not_found}
    end
  end

  defp replay_tree(path, commit, parent, onto, replayed) do
    case merge_tree_from_cache(path, onto, commit, merge_base: parent) do
      {:ok, %{tree: tree}} ->
        {:ok, tree}

      {:conflict, conflict} ->
        {:conflict,
         conflict
         |> Map.drop([:tree])
         |> Map.merge(%{commit: commit, onto: onto, replayed: Enum.reverse(replayed)})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_replayed_tree(path, original, tree, parent) do
    with {:ok, author} <- author_of(path, original),
         {message, 0} <-
           Repos.git(path, ["show", "-s", "--format=%B", "--end-of-options", original]) do
      env = [
        {"GIT_AUTHOR_NAME", author.name},
        {"GIT_AUTHOR_EMAIL", author.email},
        {"GIT_AUTHOR_DATE", author.date},
        {"GIT_COMMITTER_NAME", @committer_name},
        {"GIT_COMMITTER_EMAIL", @committer_email}
      ]

      case git_with_stdin(path, ["commit-tree", tree, "-p", parent], message, env) do
        {output, 0} -> {:ok, String.trim(output)}
        _other -> {:error, :commit_tree_failed}
      end
    else
      {:error, reason} -> {:error, reason}
      {_output, _status} -> {:error, :not_found}
    end
  end

  defp author_of(path, commit) do
    case Repos.git(path, ["show", "-s", "--format=%an%x00%ae%x00%aI", "--end-of-options", commit]) do
      {output, 0} ->
        case output |> String.trim() |> String.split("\x00", parts: 3) do
          [name, email, date] -> {:ok, %{name: name, email: email, date: date}}
          _other -> {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  ## Retention refs

  @doc """
  Build a hidden internal ref name under `refs/internal/`.

  Boundary commits stay reachable through these refs, so git's garbage
  collection never prunes them (`docs/stacked-prs.md` section 7.4). They are
  never advertised to clients: `OpenAgents.Forge.Repos.ensure_repo_at!/2`
  sets `transfer.hideRefs` to cover `refs/internal/`. Move them through
  `batch_update_refs/3` so they persist in the WAL like any other ref.
  """
  def internal_ref(segments) when is_list(segments) and segments != [] do
    if Enum.all?(segments, &valid_segment?/1) do
      {:ok, "refs/internal/" <> Enum.join(segments, "/")}
    else
      {:error, :invalid_ref}
    end
  end

  defp valid_segment?(segment) when is_binary(segment) do
    Regex.match?(@segment_pattern, segment) and not String.ends_with?(segment, ".lock")
  end

  defp valid_segment?(_segment), do: false

  ## Batch compare-and-swap ref updates

  @doc """
  Apply a batch of ref updates atomically: every ref applies or none does,
  and any mismatched expected OID rejects the whole batch.

  The updates apply through one `git update-ref --stdin` transaction under
  the per-repository lock, then persist as one WAL entry (a git bundle of
  the new objects) so cache convergence and mirrors see one transition. A
  WAL index conflict from another writer re-syncs, re-validates every
  expected OID, and retries once; a WAL persist failure rolls the local
  refs back, so the cache never gets ahead of the authority.

  Returns `{:ok, %{seq: seq, refs: refs_after}}` on success. Errors:

    * `{:error, {:expected_mismatch, ref, actual}}` — a live ref no longer
      matches its expected old OID (`actual` is the current OID or `:absent`)
    * `{:error, :invalid_update}` — malformed ref, OID, or duplicate ref
    * `{:error, :ref_update_failed}` — git rejected the transaction
    * `{:error, :wal_persist_failed}` — refs rolled back, safe to retry
  """
  def batch_update_refs(repo, updates, principal)
      when is_list(updates) and updates != [] and is_binary(principal) do
    with :ok <- validate_updates(updates) do
      Sync.with_repo_lock(repo, fn -> locked_batch(repo, updates, principal, false) end)
    end
  end

  defp validate_updates(updates) do
    refs = Enum.map(updates, &Map.get(&1, :ref))

    valid? =
      length(Enum.uniq(refs)) == length(refs) and
        Enum.all?(updates, fn update ->
          valid_ref_name?(update[:ref]) and
            valid_expected_old?(update[:expected_old]) and
            valid_new?(update[:new]) and
            not (update[:expected_old] == :absent and update[:new] == :delete)
        end)

    if valid?, do: :ok, else: {:error, :invalid_update}
  end

  defp valid_ref_name?(ref) when is_binary(ref) do
    Regex.match?(@ref_pattern, ref) and not String.contains?(ref, ["..", "//", "@{"]) and
      not String.ends_with?(ref, ["/", ".", ".lock"])
  end

  defp valid_ref_name?(_ref), do: false

  defp valid_expected_old?(:absent), do: true
  defp valid_expected_old?(oid), do: valid_oid?(oid)

  defp valid_new?(:delete), do: true
  defp valid_new?(oid), do: valid_oid?(oid)

  defp valid_oid?(oid) when is_binary(oid), do: Regex.match?(@oid_pattern, oid)
  defp valid_oid?(_oid), do: false

  defp locked_batch(repo, updates, principal, retried?) do
    with :ok <- Sync.ensure_fresh(repo) do
      path = Repos.ensure_repo!(repo)
      refs_before = Repos.refs(repo)

      with :ok <- check_expected(updates, refs_before),
           :ok <- apply_updates(path, updates) do
        refs_after = Repos.refs(repo)

        case persist_batch(repo, path, updates, refs_before, refs_after, principal) do
          {:ok, seq} ->
            Repos.record_applied_seq!(repo, seq)
            broadcast(repo, seq, refs_after)
            mirror_async(repo)
            {:ok, %{seq: seq, refs: refs_after}}

          {:error, :cas_conflict} when not retried? ->
            Repos.set_refs!(repo, refs_before)
            locked_batch(repo, updates, principal, true)

          {:error, reason} ->
            Logger.error(
              "forge_batch_update_wal_failed repo=#{repo} code=#{OpenAgents.OperationalLog.code(reason)}"
            )

            Repos.set_refs!(repo, refs_before)
            {:error, :wal_persist_failed}
        end
      end
    end
  end

  defp check_expected(updates, refs_before) do
    Enum.find_value(updates, :ok, fn update ->
      actual = Map.get(refs_before, update.ref, :absent)

      if actual == update.expected_old do
        nil
      else
        {:error, {:expected_mismatch, update.ref, actual}}
      end
    end)
  end

  defp apply_updates(path, updates) do
    zero = zero_oid(path)

    instructions =
      Enum.map_join(updates, fn update ->
        case update do
          %{new: :delete, expected_old: old} ->
            "delete " <> update.ref <> "\x00" <> old <> "\x00"

          %{new: new, expected_old: :absent} ->
            "update " <> update.ref <> "\x00" <> new <> "\x00" <> zero <> "\x00"

          %{new: new, expected_old: old} ->
            "update " <> update.ref <> "\x00" <> new <> "\x00" <> old <> "\x00"
        end
      end)

    case git_with_stdin(path, ["update-ref", "--stdin", "-z"], instructions, []) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :ref_update_failed}
    end
  end

  defp zero_oid(path) do
    case Repos.git(path, ["rev-parse", "--show-object-format"]) do
      {"sha256" <> _rest, 0} -> String.duplicate("0", 64)
      _sha1 -> String.duplicate("0", 40)
    end
  end

  # One WAL entry per batch: the new objects ride a git bundle (the existing
  # `git_bundle` replay format), so a rebuilt cache converges in one step.
  # A batch that introduces no objects (deletes, moves to known OIDs)
  # records an `empty_import` entry; refs still converge from the index.
  defp persist_batch(repo, path, updates, refs_before, refs_after, principal) do
    {expected, index} =
      case WAL.read_index(repo) do
        {:ok, generation, index} -> {generation, index}
        {:error, :not_found} -> {:none, WAL.new_index()}
        {:error, reason} -> throw({:wal_error, reason})
      end

    seq = WAL.next_seq(index)

    with {:ok, object, format} <- put_batch_entry(repo, path, seq, updates, refs_before),
         entry = %{
           "seq" => seq,
           "object" => object,
           "format" => format,
           "refs" => refs_after,
           "principal" => principal,
           "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         },
         {:ok, _generation} <- WAL.cas_index(repo, expected, WAL.append_entry(index, entry)) do
      {:ok, seq}
    end
  catch
    {:wal_error, reason} -> {:error, reason}
  end

  defp put_batch_entry(repo, path, seq, updates, refs_before) do
    positive_refs = for %{new: new} = update <- updates, new != :delete, do: update.ref
    negatives = refs_before |> Map.values() |> Enum.uniq() |> Enum.map(&("^" <> &1))

    if positive_refs == [] or not new_objects?(path, positive_refs, negatives) do
      with {:ok, object} <- WAL.put_entry(repo, seq, ""), do: {:ok, object, "ref_update"}
    else
      bundle_path =
        Path.join(
          System.tmp_dir!(),
          "forge-batch-#{System.unique_integer([:positive, :monotonic])}.bundle"
        )

      try do
        case Repos.git(path, ["bundle", "create", bundle_path | positive_refs] ++ negatives) do
          {_output, 0} ->
            with {:ok, object} <- WAL.put_entry_file(repo, seq, bundle_path) do
              {:ok, object, "git_bundle"}
            end

          {_output, _status} ->
            {:error, :bundle_create_failed}
        end
      after
        File.rm(bundle_path)
      end
    end
  end

  # `git bundle create` refuses an empty bundle, so a batch whose targets are
  # all already reachable (deletes, moves to known OIDs) records an
  # `empty_import` entry instead; refs still converge from the index.
  defp new_objects?(path, positive_refs, negatives) do
    case Repos.git(
           path,
           ["rev-list", "-n", "1", "--end-of-options"] ++ positive_refs ++ negatives
         ) do
      {output, 0} -> String.trim(output) != ""
      _other -> true
    end
  end

  defp broadcast(repo, seq, refs) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:pushes",
      {:forge_push, %{repo: repo, wal_seq: seq, refs: refs}}
    )
  end

  defp mirror_async(repo) do
    if Pushes.mirror_url(repo) do
      Task.Supervisor.start_child(OpenAgents.Forge.TaskSupervisor, fn ->
        Pushes.mirror_now(repo)
      end)
    end

    :ok
  end

  ## Internals

  defp check_rev(rev) do
    if is_binary(rev) and Regex.match?(~r|\A[A-Za-z0-9][A-Za-z0-9._/-]{0,127}\z|, rev) and
         not String.contains?(rev, ".."),
       do: :ok,
       else: {:error, :not_found}
  end

  defp check_optional_rev(nil), do: :ok
  defp check_optional_rev(rev), do: check_rev(rev)

  defp check_oid(oid), do: if(valid_oid?(oid), do: :ok, else: {:error, :not_found})

  defp git(repo, args), do: Repos.git(Repos.bare_path(repo), args)

  # `sh` is used ONLY for stdin redirection of a server-generated temp path;
  # every git argument rides argv ("$@"), never the shell string — the same
  # pattern as `OpenAgents.Forge.GitHTTP.run_git_service/4`.
  defp git_with_stdin(path, args, input, env) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "forge-git-plane-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.write!(input_path, input)

    try do
      System.cmd(
        "sh",
        [
          "-c",
          ~s(exec git "$@" < "$FORGE_GIT_PLANE_INPUT"),
          "sh",
          "--git-dir",
          path | args
        ],
        env: env ++ [{"FORGE_GIT_PLANE_INPUT", input_path}],
        stderr_to_stdout: true
      )
    after
      File.rm(input_path)
    end
  end
end
