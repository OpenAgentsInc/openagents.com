defmodule OpenAgents.Forge.Pushes do
  @moduledoc """
  The push pipeline, Continuity-shaped: apply locally, persist to the WAL,
  and only then ack — "we never acknowledge a push until it has been fully
  persisted." If the WAL will not accept the entry, local refs are rolled
  back and the client sees a failed push; the cache never gets ahead of the
  authority.

  Pushes and local cache synchronization share one per-repository lock on each
  node. The WAL index CAS remains the cluster-wide serialization point (a
  conflict from another writer is re-synced and retried once).

  After the WAL accepts: a `forge_pushes` receipt row is derived (idempotent
  by WAL sequence — audit A7: receipts are derived from the WAL, never a
  second authority), `forge:pushes` is broadcast, and the GitHub mirror is
  pushed best-effort in the background (never blocking, never load-bearing).
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.{Analytics, Repositories}
  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.{GitHTTP, PushReceipt, Repos, Sync, WAL}
  alias OpenAgents.Issues.ClosingReferences
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  @doc """
  Handle one `git-receive-pack` request body. Returns `{:ok, response_body}`
  only after WAL persist; `{:error, :wal_persist_failed}` after rollback.
  """
  def handle_receive_pack(repo, body, principal, git_protocol) do
    Sync.with_repo_lock(repo, fn ->
      do_handle(repo, body, principal, git_protocol, false)
    end)
  end

  defp do_handle(repo, body, principal, git_protocol, retried?) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- Sync.ensure_fresh(repo) do
      path = Repos.ensure_repo!(repo)
      refs_before = Repos.refs(repo)

      {output, status} = GitHTTP.run_git_service("receive-pack", [path], body, git_protocol)

      refs_after = Repos.refs(repo)

      cond do
        status != 0 ->
          {:error, :receive_pack_failed}

        refs_after == refs_before ->
          # Nothing changed (up to date, or all commands rejected by git);
          # the client's report-status in `output` says why. Nothing to persist.
          {:ok, output}

        true ->
          case persist(repo, body, refs_after, principal) do
            {:ok, seq} ->
              Repos.record_applied_seq!(repo, seq)
              record_repository_activity(repo)

              capture_push_received(
                repo,
                record_receipt(repo, seq, refs_before, refs_after, principal, started_at),
                refs_before,
                refs_after,
                started_at
              )

              broadcast(repo, seq, refs_after)
              mirror_async(repo)
              {:ok, output}

            {:error, :cas_conflict} when not retried? ->
              with :ok <- Sync.ensure_fresh(repo) do
                do_handle(repo, body, principal, git_protocol, true)
              end

            {:error, reason} ->
              Logger.error(
                "forge_push_wal_failed repo=#{repo} code=#{OpenAgents.OperationalLog.code(reason)}"
              )

              Repos.set_refs!(repo, refs_before)
              {:error, :wal_persist_failed}
          end
      end
    end
  end

  # Live-push analytics only. Crash-recovery reconciliation reuses
  # `record_receipt/5` without capturing, so recovered rows never double count.
  defp capture_push_received(repo, {:ok, _receipt}, refs_before, refs_after, started_at) do
    Analytics.capture("git_push_received", Analytics.system_distinct_id("forge"), %{
      "repo" => repo,
      "refs_changed" => Enum.count(refs_after, fn {name, sha} -> refs_before[name] != sha end),
      "duration_ms" => System.monotonic_time(:millisecond) - started_at
    })
  end

  defp capture_push_received(_repo, :error, _before, _after, _started_at), do: :ok

  # Repository timestamps are a derived product projection, not part of the
  # WAL acknowledgment barrier. A database outage must not turn a persisted
  # push into an apparent client failure, because retrying would duplicate a
  # push the forge already accepted.
  defp record_repository_activity(repo) do
    case Repositories.record_push_activity(repo) do
      :ok ->
        :ok

      {:error, :repository_not_found} ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "forge_push_repository_activity_failed code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :ok
  end

  # ── WAL persist (ack barrier) ───────────────────────────────────────────

  defp persist(repo, body, refs_after, principal) do
    {expected, index} =
      case WAL.read_index(repo) do
        {:ok, generation, index} -> {generation, index}
        {:error, :not_found} -> {:none, WAL.new_index()}
        {:error, reason} -> throw({:wal_error, reason})
      end

    seq = WAL.next_seq(index)

    with {:ok, object} <- WAL.put_entry(repo, seq, body),
         entry = %{
           "seq" => seq,
           "object" => object,
           "format" => "receive_pack",
           "refs" => refs_after,
           "principal" => principal,
           "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         },
         {:ok, _generation} <- WAL.cas_index(repo, expected, WAL.append_entry(index, entry)) do
      {:ok, seq}
    else
      {:error, reason} ->
        {:error, reason}
    end
  catch
    {:wal_error, reason} -> {:error, reason}
  end

  # ── derived records (never authority) ───────────────────────────────────

  @doc """
  F1 (#124, audit A7): reconcile the derived `forge_pushes` receipts from
  the WAL — exactly once, keyed by WAL index position. Any receipt lost to
  a crash between WAL persist and the Postgres insert (or to a database
  restore) is re-derived from the entries; existing rows are untouched
  (`on_conflict: :nothing` on `(repo, wal_seq)`). Refs never live in
  Postgres — this derives records FROM the WAL, the one ref truth.

  Returns the number of receipts inserted.
  """
  def reconcile_receipts(repo) do
    case WAL.read_index(repo) do
      {:ok, _generation, index} ->
        existing =
          PushReceipt
          |> where([p], p.repo == ^repo)
          |> select([p], p.wal_seq)
          |> Repo.all()
          |> MapSet.new()

        index
        |> WAL.entries()
        |> Enum.map_reduce(%{}, fn entry, refs_before ->
          {{entry, refs_before}, entry["refs"]}
        end)
        |> elem(0)
        |> Enum.reject(fn {entry, _before} -> MapSet.member?(existing, entry["seq"]) end)
        |> Enum.count(fn {entry, refs_before} ->
          match?(
            {:ok, _receipt},
            record_receipt(
              repo,
              entry["seq"],
              refs_before,
              entry["refs"],
              entry["principal"] || "unknown",
              System.monotonic_time(:millisecond)
            )
          )
        end)

      {:error, _reason} ->
        0
    end
  end

  defp record_receipt(repo, seq, refs_before, refs_after, principal, started_at) do
    changed =
      refs_after
      |> Enum.filter(fn {name, sha} -> refs_before[name] != sha end)
      |> Map.new(fn {name, sha} -> {name, %{"old" => refs_before[name], "new" => sha}} end)

    deleted =
      refs_before
      |> Enum.reject(fn {name, _} -> Map.has_key?(refs_after, name) end)
      |> Map.new(fn {name, sha} -> {name, %{"old" => sha, "new" => nil}} end)

    result =
      %PushReceipt{}
      |> PushReceipt.changeset(%{
        repo: repo,
        wal_seq: seq,
        principal: principal,
        refs: Map.merge(changed, deleted),
        duration_ms: System.monotonic_time(:millisecond) - started_at
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:repo, :wal_seq])

    # Both the live push and the WAL replayer reach the issue tracker through
    # here, so one idempotency gate covers both.
    close_referenced_issues(repo, seq, refs_before, refs_after, principal)

    result
  rescue
    error ->
      Logger.error("forge_push_receipt_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :error
  end

  # ── closing references (#130) ───────────────────────────────────────────

  @doc """
  Close the issues that this push's default-branch commits say they close.

  Default branch only: a commit on a topic branch records nothing, and the
  same commit closes the issue when it arrives on the default branch. That is
  the property that stops an unmerged branch from closing work.

  Nothing here can fail a push. It runs after the WAL ack barrier and after
  the receipt insert, and every error — a malformed reference, an unreadable
  repository, an issue tracker that will not answer — is caught and logged.
  The push is already durable by the time this runs; refusing it now would
  ask a client to retry a push the forge has accepted.
  """
  def close_referenced_issues(repo, seq, refs_before, refs_after, principal) do
    with %Repository{} = repository <- repository_for(repo),
         %User{} = actor <- push_actor(principal),
         [_ | _] = commits <- default_branch_commits(repo, repository, refs_before, refs_after) do
      receipt_id = receipt_id(repo, seq)

      context = [
        repo: repo,
        wal_seq: seq,
        push_receipt_id: receipt_id,
        principal: principal
      ]

      Enum.each(commits, fn {sha, message} ->
        ClosingReferences.apply_commit(repository, actor, sha, message, context)
      end)

      :ok
    else
      _nothing_to_do -> :ok
    end
  rescue
    error ->
      Logger.warning(
        "forge_push_closing_references_failed repo=#{repo} code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "forge_push_closing_references_failed repo=#{repo} code=#{OpenAgents.OperationalLog.code({kind, reason})}"
      )

      :ok
  end

  # No single push closes more than this. The cap bounds the tracker work one
  # push can ask for, however much history a first push to the default branch
  # carries.
  @closing_commit_limit 200

  @doc """
  The commits this push newly made reachable from the repository's default
  branch, as `{sha, message}` pairs, newest first.

  A force push that rewinds or rewrites the branch presents whatever is
  reachable from the new tip and not from the old one; commits it re-presents
  are stopped by the `{issue_id, commit_sha}` gate rather than by this range.
  """
  def default_branch_commits(repo, %Repository{} = repository, refs_before, refs_after) do
    ref = "refs/heads/" <> (repository.default_branch || "main")
    old = Map.get(refs_before || %{}, ref)
    new = Map.get(refs_after || %{}, ref)

    cond do
      is_nil(new) -> []
      new == old -> []
      true -> read_commits(repo, old, new)
    end
  end

  def default_branch_commits(_repo, _repository, _refs_before, _refs_after), do: []

  defp read_commits(repo, old, new) do
    range =
      if is_binary(old) and old != "" and old != String.duplicate("0", byte_size(old)),
        do: [new, "--not", old],
        else: [new]

    args =
      ["log", "--format=%H%x00%B%x01", "--max-count=#{@closing_commit_limit}"] ++
        range ++ ["--"]

    case Repos.git(Repos.bare_path(repo), args) do
      {output, 0} -> parse_commits(output)
      _unreadable -> []
    end
  end

  defp parse_commits(output) do
    output
    |> String.split("\x01", trim: true)
    |> Enum.flat_map(fn record ->
      case record |> String.trim_leading("\n") |> String.split("\x00", parts: 2) do
        [sha, message] -> [{String.trim(sha), message}]
        _unparseable -> []
      end
    end)
  end

  defp repository_for(repo) when is_binary(repo) do
    Repo.one(from repository in Repository, where: repository.storage_key == ^repo)
  end

  defp repository_for(_repo), do: nil

  # Only a user principal closes an issue, and the close is attributed to
  # them. An operator token, a machine, and an assignment credential push
  # without an accountable person behind the close, so they record nothing.
  defp push_actor("user:" <> id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  defp push_actor(_principal), do: nil

  defp receipt_id(repo, seq) do
    Repo.one(
      from receipt in PushReceipt,
        where: receipt.repo == ^repo and receipt.wal_seq == ^seq,
        select: receipt.id
    )
  end

  defp broadcast(repo, seq, refs) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:pushes",
      {:forge_push, %{repo: repo, wal_seq: seq, refs: refs}}
    )
  end

  # ── mirror (best-effort, one-way, never load-bearing) ───────────────────

  defp mirror_async(repo) do
    case mirror_url(repo) do
      nil ->
        :ok

      _url ->
        Task.Supervisor.start_child(OpenAgents.Forge.TaskSupervisor, fn -> mirror_now(repo) end)
    end
  end

  @doc """
  Push the bare repo to its configured mirror, synchronously (#127). One-way,
  best-effort, never load-bearing: a failure logs and returns an error for
  the drift watcher to count — it never blocks or fails a forge push. The
  mirror URL must not embed a credential; authentication belongs to the git
  credential helper or workload identity and output is never logged.
  """
  def mirror_now(repo) do
    case mirror_url(repo) do
      nil ->
        {:error, :mirror_unconfigured}

      url ->
        path = repo |> mirror_storage_key() |> Repos.bare_path()

        case Repos.git(path, ["push", "--mirror", url]) do
          {_, 0} ->
            :ok

          {_output, _} ->
            Logger.warning("forge_mirror_failed repo=#{repo} code=mirror_push_failed")
            {:error, :mirror_push_failed}
        end
    end
  end

  @doc "The configured mirror URL for a repo, or nil (config `:forge_mirror_urls`)."
  def mirror_url(repo) do
    case Application.get_env(:openagents, :forge_mirror_urls, %{}) do
      %{} = urls -> clean_mirror_url(urls[repo] || urls[repository_name(repo)])
      _ -> nil
    end
  end

  @doc "Resolve a configured repository name or storage key to its bare-cache storage key."
  def mirror_storage_key(repo) when is_binary(repo) do
    storage_key_for_storage_key(repo) || storage_key_for_name(repo) || repo
  rescue
    _database_unavailable -> repo
  end

  def mirror_storage_key(repo), do: repo

  @doc "Return the logical and canonical repository keys used by derived push receipts."
  def receipt_repo_keys(repo) when is_binary(repo) do
    [repo, mirror_storage_key(repo)]
    |> Enum.uniq()
  end

  def receipt_repo_keys(repo), do: [repo]

  defp storage_key_for_storage_key(storage_key) do
    Repo.one(
      from repository in Repository,
        where: repository.storage_key == ^storage_key,
        select: repository.storage_key
    )
  end

  defp storage_key_for_name(name) do
    Repo.one(
      from repository in Repository,
        where: repository.name == ^name,
        select: repository.storage_key
    )
  end

  defp repository_name(storage_key) when is_binary(storage_key) do
    Repo.one(
      from repository in Repository,
        where: repository.storage_key == ^storage_key,
        select: repository.name
    )
  rescue
    _database_unavailable -> nil
  end

  defp repository_name(_storage_key), do: nil

  defp clean_mirror_url(nil), do: nil

  defp clean_mirror_url(url) when is_binary(url) do
    cond do
      String.contains?(url, ["\n", "\r", "\0"]) ->
        nil

      Path.type(url) == :absolute ->
        url

      true ->
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host, userinfo: userinfo}}
          when scheme in ["http", "https", "git", "ssh"] and is_binary(host) ->
            if is_nil(userinfo) or (scheme == "ssh" and clean_ssh_username?(userinfo)),
              do: url,
              else: nil

          _credentialed_or_invalid ->
            nil
        end
    end
  end

  defp clean_mirror_url(_invalid), do: nil

  defp clean_ssh_username?(userinfo) do
    is_binary(userinfo) and userinfo != "" and
      not String.contains?(userinfo, [":", "@", "/", "\\"])
  end
end
