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
    path = Repos.bare_path(repo)

    case entry["format"] || "receive_pack" do
      "receive_pack" ->
        {:ok, payload} = WAL.get_entry(repo, object)
        {_output, 0} = run_receive_pack(path, payload)

      "git_bundle" ->
        :ok = unbundle_entry(repo, path, object, entry["shallow"] || [])

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
end
