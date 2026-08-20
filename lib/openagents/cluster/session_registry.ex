defmodule OpenAgents.Cluster.SessionRegistry do
  @moduledoc """
  The Raft state machine (Ra) for Sarah's authoritative live-session registry.

  This is the AXD301 core of M1: the small slice of state that must survive a
  node dying is committed through Raft consensus, so it is strongly consistent,
  quorum-committed, and partition-safe. It holds, per live session
  (turn/job/delegation/voice), the **ownership generation** — a monotonic fence
  — plus the current owner node and the last committed checkpoint.

  The fence is the whole point: a `claim` bumps the generation and returns it to
  the claimer; every later mutation (`checkpoint`, `finish`) must present that
  generation, and the machine rejects a stale one. So a session resurrected on a
  survivor (generation N) supersedes any zombie still holding generation N-1 on
  a rejoining partitioned node — the zombie's writes are fenced out cluster-wide,
  not merely locally.

  Pure and deterministic by construction (`apply/3` is a total function of the
  command and prior state, no side effects, no wall clock), which is what makes
  it a valid Raft machine and trivially unit-testable without a running cluster.
  """

  @behaviour :ra_machine

  # apply/3 is the ra_machine callback; it must not resolve to Kernel.apply/3.
  import Kernel, except: [apply: 3]

  @type session_id :: term()
  @type generation :: non_neg_integer()
  @type entry :: %{
          kind: term(),
          generation: generation(),
          owner: node() | nil,
          status: :claimed | :terminal,
          checkpoint: term()
        }

  @impl true
  def init(_config), do: %{sessions: %{}}

  @impl true
  # Claim (or re-claim, on handoff) ownership of a session: bump the generation,
  # record the new owner. A terminal session is never re-claimed. Reply carries
  # the new generation — the caller's fence token.
  def apply(_meta, {:claim, id, kind, owner}, %{sessions: sessions} = state) do
    case Map.get(sessions, id) do
      %{status: :terminal} = entry ->
        {state, {:error, {:terminal, entry.generation}}}

      current ->
        generation = ((current && current.generation) || 0) + 1

        entry = %{
          kind: kind,
          generation: generation,
          owner: owner,
          status: :claimed,
          checkpoint: current && current.checkpoint
        }

        {put_session(state, id, entry), {:ok, generation}}
    end
  end

  # Commit a bounded checkpoint — but only if the caller still holds the current
  # generation. A stale generation (a superseded zombie) is fenced.
  def apply(_meta, {:checkpoint, id, generation, data}, %{sessions: sessions} = state) do
    with_owned(state, sessions, id, generation, fn entry ->
      %{entry | checkpoint: data}
    end)
  end

  # Mark a session terminal (its owner finished it). Fenced on a stale generation
  # so a zombie can never terminal-commit over the live owner.
  def apply(_meta, {:finish, id, generation}, %{sessions: sessions} = state) do
    with_owned(state, sessions, id, generation, fn entry ->
      %{entry | status: :terminal}
    end)
  end

  # Drop a session entry entirely (owner released it cleanly). Fenced.
  def apply(_meta, {:release, id, generation}, %{sessions: sessions} = state) do
    case Map.get(sessions, id) do
      %{generation: ^generation} ->
        {%{state | sessions: Map.delete(sessions, id)}, :ok}

      other ->
        {state, {:fenced, other && other.generation}}
    end
  end

  # ── query builders (used with :ra.consistent_query) ────────────────────────

  @doc "A linearizable query function returning the entry for `id` (or nil)."
  def lookup(id), do: fn %{sessions: sessions} -> Map.get(sessions, id) end

  @doc "A linearizable query function returning all session ids owned by `node`."
  def owned_by(owner) do
    fn %{sessions: sessions} ->
      for {id, %{owner: ^owner, status: :claimed}} <- sessions, do: id
    end
  end

  # ── internal ───────────────────────────────────────────────────────────────

  defp with_owned(state, sessions, id, generation, update) do
    case Map.get(sessions, id) do
      %{generation: ^generation, status: :claimed} = entry ->
        {put_session(state, id, update.(entry)), :ok}

      other ->
        {state, {:fenced, other && other.generation}}
    end
  end

  defp put_session(%{sessions: sessions} = state, id, entry),
    do: %{state | sessions: Map.put(sessions, id, entry)}
end
