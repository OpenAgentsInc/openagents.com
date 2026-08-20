defmodule OpenAgents.Forge.Sync do
  @moduledoc """
  Cache freshness against the WAL: the bare repo on disk is a projection of
  the WAL, never authority. `ensure_fresh/1` compares the repo's applied WAL
  sequence to the index and replays any missing entries (each entry is the
  raw `receive-pack --stateless-rpc` request that produced it, so replay is
  exact). A deleted repo re-materializes from seq 0 the same way.
  """

  require Logger

  alias OpenAgents.Forge.{GitHTTP, Repos, WAL}

  @doc """
  Bring the local bare repo up to the WAL. Returns `:ok` (fresh, replayed,
  or nothing pushed yet) — read paths degrade to serving the local cache if
  the WAL is unreachable, logging honestly, rather than failing reads.
  """
  def ensure_fresh(repo, default_branch \\ "main") do
    case WAL.read_index(repo) do
      {:error, :not_found} ->
        :ok

      {:ok, _generation, index} ->
        replay_missing(repo, index, default_branch)

      {:error, reason} ->
        Logger.warning(
          "forge_sync_wal_unreachable repo=#{repo} code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        :ok
    end
  end

  @doc "Replay WAL entries the local repo has not applied. Used by reads and boot."
  def replay_missing(repo, index, default_branch \\ "main") do
    Repos.ensure_repo!(repo, default_branch)
    applied = Repos.applied_seq(repo)

    index
    |> WAL.entries()
    |> Enum.filter(fn entry -> entry["seq"] > applied end)
    |> Enum.each(fn entry -> apply_entry!(repo, entry) end)

    converge_refs(repo, index)
    Repos.set_default_branch!(repo, default_branch)
    :ok
  end

  defp apply_entry!(repo, %{"seq" => seq, "object" => object} = entry) do
    {:ok, payload} = WAL.get_entry(repo, object)
    path = Repos.bare_path(repo)

    case entry["format"] || "receive_pack" do
      "receive_pack" ->
        {_output, 0} = run_receive_pack(path, payload)

      "git_bundle" ->
        :ok = unbundle(path, payload)

      "empty_import" ->
        :ok
    end

    Repos.record_applied_seq!(repo, seq)
  end

  # Replay is exact in the common case; converge_refs makes the final state
  # authoritative even if an individual replayed request was non-idempotent
  # (e.g. a non-fast-forward the original push forced).
  defp converge_refs(repo, index) do
    target = WAL.refs(index)

    if Repos.refs(repo) != target do
      Repos.set_refs!(repo, target)
    end
  end

  defp unbundle(path, payload) do
    temporary_path =
      Path.join(
        System.tmp_dir!(),
        "openagents-import-#{System.unique_integer([:positive, :monotonic])}.bundle"
      )

    try do
      File.write!(temporary_path, payload, [:binary, :exclusive])
      File.chmod!(temporary_path, 0o600)

      case Repos.git(path, ["bundle", "unbundle", temporary_path]) do
        {_output, 0} -> :ok
        {_output, _status} -> raise "repository bundle could not be materialized"
      end
    after
      File.rm(temporary_path)
    end
  end

  defp run_receive_pack(path, payload) do
    GitHTTP.run_git_service("receive-pack", [path], payload, nil)
  end
end
