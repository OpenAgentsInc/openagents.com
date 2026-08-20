defmodule OpenAgents.Cluster.Sessions do
  @moduledoc """
  Single-node-safe facade over the Ra session registry (`OpenAgents.Cluster.Ra`).

  When the Raft cluster is formed (the fleet), ownership and checkpoints commit
  through consensus and are fenced cluster-wide. When it is not (the
  single-instance Cloud Run runtime, or any node before the cluster forms),
  every call is a safe no-op that returns a local sentinel, so callers work
  identically without Raft.

  Ra holds only the in-flight slice; Postgres remains the durable ledger and the
  terminal-commit authority (`OpenAgents.Work.finish_job` is already idempotent under
  a row lock). This facade is what the Work servers use to publish the
  cluster-wide "who owns this session" assignment and to stash the bounded
  checkpoint a survivor rehydrates from.
  """

  alias OpenAgents.Cluster.Ra

  @local_generation :local

  @doc "True when the Raft cluster is formed and reachable from this node."
  def enabled? do
    Application.get_env(:openagents, :ra_enabled, false) and Ra.members() != []
  rescue
    _ -> false
  end

  @doc """
  Claim/adopt ownership of a session. Returns `{:ok, generation}`; the
  generation is the fence token for later `checkpoint/3` and `finish/2`. Off the
  cluster it returns `{:ok, :local}` and later calls no-op.
  """
  def claim(id, kind) do
    if enabled?() do
      case Ra.claim(id, kind) do
        {:ok, generation} -> {:ok, generation}
        other -> {:error, other}
      end
    else
      {:ok, @local_generation}
    end
  end

  @doc "Commit a bounded checkpoint under the held generation (fenced). No-op off-cluster."
  def checkpoint(_id, @local_generation, _data), do: :ok

  def checkpoint(id, generation, data) do
    if enabled?(), do: normalize(Ra.checkpoint(id, generation, data)), else: :ok
  end

  @doc "Mark a session terminal under the held generation (fenced). No-op off-cluster."
  def finish(_id, @local_generation), do: :ok

  def finish(id, generation) do
    if enabled?(), do: normalize(Ra.finish(id, generation)), else: :ok
  end

  @doc "Release a session entry under the held generation. No-op off-cluster."
  def release(_id, @local_generation), do: :ok

  def release(id, generation) do
    if enabled?(), do: normalize(Ra.release(id, generation)), else: :ok
  end

  @doc "Linearizable read of a session entry, or `{:ok, nil}` off-cluster."
  def lookup(id) do
    if enabled?(), do: Ra.lookup(id), else: {:ok, nil}
  end

  defp normalize(:ok), do: :ok
  defp normalize({:fenced, current}), do: {:fenced, current}
  defp normalize(other), do: {:error, other}
end
