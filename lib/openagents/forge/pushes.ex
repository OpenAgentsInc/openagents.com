defmodule OpenAgents.Forge.Pushes do
  @moduledoc """
  The push pipeline, Continuity-shaped: apply locally, persist to the WAL,
  and only then ack — "we never acknowledge a push until it has been fully
  persisted." If the WAL will not accept the entry, local refs are rolled
  back and the client sees a failed push; the cache never gets ahead of the
  authority.

  Pushes serialize per repo cluster-wide via `:global.trans`; the WAL index
  CAS remains the true serialization point (a conflict from a writer outside
  the cluster is re-synced and retried once).

  After the WAL accepts: a `forge_pushes` receipt row is derived (idempotent
  by WAL sequence — audit A7: receipts are derived from the WAL, never a
  second authority), `forge:pushes` is broadcast, and the GitHub mirror is
  pushed best-effort in the background (never blocking, never load-bearing).
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.{GitHTTP, PushReceipt, Repos, Sync, WAL}
  alias OpenAgents.Repo

  @doc """
  Handle one `git-receive-pack` request body. Returns `{:ok, response_body}`
  only after WAL persist; `{:error, :wal_persist_failed}` after rollback.
  """
  def handle_receive_pack(repo, body, principal, git_protocol) do
    :global.trans({{:forge_push, repo}, self()}, fn ->
      do_handle(repo, body, principal, git_protocol)
    end)
  end

  defp do_handle(repo, body, principal, git_protocol) do
    started_at = System.monotonic_time(:millisecond)
    Sync.ensure_fresh(repo)
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
            record_receipt(repo, seq, refs_before, refs_after, principal, started_at)
            broadcast(repo, seq, refs_after)
            mirror_async(repo)
            {:ok, output}

          {:error, reason} ->
            Logger.error("forge push: WAL persist failed for #{repo}: #{inspect(reason)}")
            Repos.set_refs!(repo, refs_before)
            {:error, :wal_persist_failed}
        end
    end
  end

  # ── WAL persist (ack barrier) ───────────────────────────────────────────

  defp persist(repo, body, refs_after, principal, retried? \\ false) do
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
           "refs" => refs_after,
           "principal" => principal,
           "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         },
         {:ok, _generation} <- WAL.cas_index(repo, expected, WAL.append_entry(index, entry)) do
      {:ok, seq}
    else
      {:error, :cas_conflict} when not retried? ->
        # Someone else advanced the WAL. Re-sync the cache (their entries
        # replay on top of ours only if compatible; converge_refs settles it)
        # and try once more from the new head.
        Sync.ensure_fresh(repo)
        persist(repo, body, Repos.refs(repo), principal, true)

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

    %PushReceipt{}
    |> PushReceipt.changeset(%{
      repo: repo,
      wal_seq: seq,
      principal: principal,
      refs: Map.merge(changed, deleted),
      duration_ms: System.monotonic_time(:millisecond) - started_at
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:repo, :wal_seq])
  rescue
    error ->
      Logger.error("forge push: receipt insert failed: #{inspect(error)}")
      :error
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
  mirror URL may embed a credential and is never included in logs or output.
  """
  def mirror_now(repo) do
    case mirror_url(repo) do
      nil ->
        {:error, :mirror_unconfigured}

      url ->
        path = Repos.bare_path(repo)

        case Repos.git(path, ["push", "--mirror", url]) do
          {_, 0} ->
            :ok

          {output, _} ->
            Logger.warning("forge mirror failed for #{repo}: #{bounded(redact(output, url))}")
            {:error, :mirror_push_failed}
        end
    end
  end

  @doc "The configured mirror URL for a repo, or nil (config `:forge_mirror_urls`)."
  def mirror_url(repo) do
    case Application.get_env(:openagents, :forge_mirror_urls, %{}) do
      %{} = urls -> urls[repo]
      _ -> nil
    end
  end

  # git sometimes prints the remote URL (with credential) in errors.
  defp redact(output, url), do: String.replace(output, url, "[mirror]")

  defp bounded(text), do: String.slice(text, 0, 500)
end
