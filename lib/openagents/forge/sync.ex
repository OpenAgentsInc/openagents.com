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
  def ensure_fresh(repo) do
    case WAL.read_index(repo) do
      {:error, :not_found} ->
        :ok

      {:ok, _generation, index} ->
        replay_missing(repo, index)

      {:error, reason} ->
        Logger.warning("forge sync: WAL unreachable for #{repo}: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Replay WAL entries the local repo has not applied. Used by reads and boot."
  def replay_missing(repo, index) do
    Repos.ensure_repo!(repo)
    applied = Repos.applied_seq(repo)

    index
    |> WAL.entries()
    |> Enum.filter(fn entry -> entry["seq"] > applied end)
    |> Enum.each(fn entry -> apply_entry!(repo, entry) end)

    converge_refs(repo, index)
    :ok
  end

  defp apply_entry!(repo, %{"seq" => seq, "object" => object}) do
    {:ok, payload} = WAL.get_entry(repo, object)
    path = Repos.bare_path(repo)
    {_output, 0} = run_receive_pack(path, payload)
    Repos.record_applied_seq!(repo, seq)
  end

  # Replay is exact in the common case; converge_refs makes the final state
  # authoritative even if an individual replayed request was non-idempotent
  # (e.g. a non-fast-forward the original push forced).
  defp converge_refs(repo, index) do
    target = WAL.refs(index)

    if target != %{} and Repos.refs(repo) != target do
      Repos.set_refs!(repo, target)
    end
  end

  defp run_receive_pack(path, payload) do
    GitHTTP.run_git_service("receive-pack", [path], payload, nil)
  end
end
