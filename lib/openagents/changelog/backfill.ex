defmodule OpenAgents.Changelog.Backfill do
  @moduledoc """
  The one-time changelog seed (spec §3 "Backfill"): the curated entries from
  `CHANGELOG.md` — everything built 2026-08-16 → 2026-08-19 — inserted
  idempotently (`ON CONFLICT DO NOTHING` on `{repo, sha, source}`) so the
  public page is full on day one and re-running is always safe.

  Runs as a temporary boot task in prod (`:changelog_backfill_on_boot`),
  after migrate-on-boot; failures are logged, never fatal — an empty
  changelog is a degraded page, not a down system.
  """

  require Logger

  alias OpenAgents.Changelog

  @repo "sarah"

  @doc "Boot entrypoint: seed if configured, never raise."
  def boot do
    if Application.get_env(:sarah, :changelog_backfill_on_boot, false) do
      run()
    end

    :ok
  rescue
    error -> Logger.warning("changelog backfill failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("changelog backfill exited: #{inspect(reason)}")
  end

  @doc "Insert every seed entry idempotently. Returns the inserted count."
  def run do
    Enum.count(entries(), fn attrs ->
      case Changelog.record(Map.merge(attrs, %{repo: @repo, source: "backfill"})) do
        {:ok, %{id: id}} when not is_nil(id) -> true
        _ -> false
      end
    end)
  end

  @doc "The curated seed, lead-commit-anchored, from CHANGELOG.md."
  def entries do
    [
      # ── 2026-08-19 (later) — the transparency surfaces themselves
      e(
        ~U[2026-08-19 17:30:00Z],
        "e672f92",
        "forge",
        "This changelog went public, and the forge got a web UI: browse any file at a stable URL, and see each commit's deploy story from the receipt chain."
      ),

      # ── 2026-08-19 — the forge becomes canonical; Sarah ships her own code
      e(
        ~U[2026-08-19 16:45:00Z],
        "24ea5ac",
        "forge",
        "Transparency spec + the first two-layer changelog: L0–L3 disclosure levels, agent-trace digest commitments, and the T1–T7 roadmap."
      ),
      e(
        ~U[2026-08-19 14:29:00Z],
        "187da5a",
        "forge",
        "The forge is canonical: all pushes go to openagents.com/git; GitHub is a read-only mirror with drift watching."
      ),
      e(
        ~U[2026-08-19 13:35:00Z],
        "34a2666",
        "agents",
        "Cloud machines: Sarah's computer controllers run on GCE VMs, with no GCP identity and read-only deploy keys."
      ),
      e(~U[2026-08-19 13:02:00Z], "3a236b6", "ui", "Centered the ghost mic button icon."),
      e(
        ~U[2026-08-19 07:53:00Z],
        "5166e09f",
        "forge",
        "Sarah edited her own source code for the first time: read → edit → verify → commit → push, live on all 3 nodes 55.4 s after her push."
      ),
      e(
        ~U[2026-08-19 07:16:00Z],
        "efdb233",
        "forge",
        "Self-editing shipped behind SELF-EDIT-001: governed coding jobs on per-job clones; promotion stays a human click."
      ),
      e(
        ~U[2026-08-19 07:21:00Z],
        "3271c53",
        "forge",
        "Nodes converge from the WAL on boot, a break-glass push lane exists, and image bakes leave the critical path."
      ),
      e(
        ~U[2026-08-19 06:00:00Z],
        "3e515c4",
        "fix",
        "Fixed the empty-manifest defect that let a build go \"live\" with zero modules (the c92f1889 incident)."
      ),
      e(
        ~U[2026-08-19 05:38:00Z],
        "d82d174",
        "feature",
        "openagents.com/status became the public network page: fleet, quorum, and the live rollout pipeline with push→live timing."
      ),
      e(
        ~U[2026-08-19 05:13:00Z],
        "8f9404e",
        "fix",
        "Interrupted background work resumes from its checkpointed agent session instead of being marked dead."
      ),
      e(
        ~U[2026-08-19 04:01:00Z],
        "70c34ba",
        "forge",
        "The hot-load deploy lane shipped: push → promote → incremental build → canary → fleet-wide live, receipted; first loop 13.2 s push→live."
      ),
      e(
        ~U[2026-08-19 03:44:00Z],
        "677c9ba",
        "forge",
        "Sarah serves her own git: smart-HTTP forge at openagents.com/git, pushes acked only after WAL persist to object storage."
      ),
      e(
        ~U[2026-08-19 03:41:00Z],
        "eb93e53",
        "infra",
        "Releases are gated by owned chaos drills — node kill, Raft partition, SIGKILL-mid-upgrade — on our own machines, no hosted CI."
      ),
      e(
        ~U[2026-08-19 02:47:00Z],
        "c0a96f1",
        "infra",
        "Live in-place hot code upgrade (relup) proven on the fleet: 0.1.0 → 0.2.0 with state migrated and no restart."
      ),

      # ── 2026-08-18 — the Immortal Sarah build day
      e(
        ~U[2026-08-19 00:43:00Z],
        "2071eaf",
        "infra",
        "Zero-downtime rolling node replacement: drain, replace, rejoin — the cluster never loses quorum during a deploy."
      ),
      e(
        ~U[2026-08-18 23:21:00Z],
        "e6c7358",
        "infra",
        "Background jobs survive node death: cluster-wide singletons relocate via Horde with a Postgres ownership fence."
      ),
      e(
        ~U[2026-08-18 21:12:00Z],
        "f6afd61",
        "infra",
        "Sarah became a 3-node clustered BEAM fleet on GCE — the single-instance Cloud Run era ended."
      ),
      e(
        ~U[2026-08-18 23:13:00Z],
        "1d5485d",
        "agents",
        "Delegation hardening: typed incidents on timeout/refuse/cancel, decoded reports, resumable sessions, per-job time walls."
      ),
      e(
        ~U[2026-08-18 17:29:00Z],
        "13e1f3f",
        "ui",
        "Non-blocking composer: messages and delegations queue while Sarah works instead of locking the input."
      ),
      e(
        ~U[2026-08-18 16:21:00Z],
        "59d8259",
        "feature",
        "Sarah self-heals: errors become durable typed incidents she can look up, triage, and — behind a gate — fix."
      ),
      e(
        ~U[2026-08-18 13:02:00Z],
        "f47c89f",
        "ui",
        "The delegation rail: live tool cards for background agent work, collapsible and patch-stable."
      ),

      # ── 2026-08-17 — voice in production, the design system, computers
      e(
        ~U[2026-08-18 03:05:00Z],
        "4189c37",
        "agents",
        "computer_agent.v1: delegate work to any ACP coding agent — Claude, Devin, Codex — on a paired machine."
      ),
      e(
        ~U[2026-08-18 03:28:00Z],
        "387cf8a",
        "ui",
        "The OpenAgentsWeb.UI design system landed: every surface renders through governed components over vendored Basecoat."
      ),
      e(
        ~U[2026-08-18 00:49:00Z],
        "b71790d",
        "feature",
        "The whole conversation exports as one ATIF v1.7 trajectory: every tool call, raw arguments, durable outcomes, usage."
      ),
      e(
        ~U[2026-08-18 00:47:00Z],
        "7b4a926",
        "agents",
        "deep_work.v1: durable background jobs that outlast the turn and report back into the conversation."
      ),
      e(~U[2026-08-18 00:28:00Z], "7868f9b", "voice", "Voice mode enabled in production."),
      e(
        ~U[2026-08-17 23:56:00Z],
        "f92dbfa",
        "voice",
        "Fixed the live voice stall and cross-generation amnesia; realtime sessions survive parallel tool calls and races."
      ),
      e(
        ~U[2026-08-17 19:26:00Z],
        "a218029",
        "agents",
        "Computer pairing: Sarah requests work on your machines through the open-source controller, and the machine enforces policy."
      ),
      e(
        ~U[2026-08-17 18:11:00Z],
        "bb25630",
        "feature",
        "Sarah reads your GitHub repositories through your own login's OAuth token."
      ),
      e(
        ~U[2026-08-17 17:08:00Z],
        "b65dd7d",
        "feature",
        "A live public token leaderboard at /leaderboard — the first public projection surface."
      ),
      e(
        ~U[2026-08-17 10:12:00Z],
        "2333e40",
        "memory",
        "Profile memories store automatically and are correctable — no magic words required."
      ),

      # ── 2026-08-16 — day one: Simply Sarah
      e(
        ~U[2026-08-17 01:05:00Z],
        "d1d9b74",
        "feature",
        "GitHub authentication required to interact; the first production release shipped the same day."
      ),
      e(
        ~U[2026-08-16 23:54:00Z],
        "9bd267b",
        "privacy",
        "Deletion is complete by construction: privacy deletion preserved across recall, preferences, and derived memory."
      ),
      e(
        ~U[2026-08-16 22:51:00Z],
        "3b7da79",
        "feature",
        "The module registry and the Khala governance chain: nine gates from private consent to operator publication."
      ),
      e(
        ~U[2026-08-16 21:45:00Z],
        "2abf67f",
        "voice",
        "OpenAI Realtime voice transport decided and proven, with a durable generation-fenced voice runtime."
      ),
      e(
        ~U[2026-08-16 20:42:00Z],
        "c53e7c2",
        "feature",
        "Persona as a governed artifact: pinned canon, installed role, and a persona regression gate on every release."
      ),
      e(
        ~U[2026-08-16 17:23:00Z],
        "0fd4c83",
        "feature",
        "Day one: the Simply Sarah conversation app — one canonical, durable conversation per GitHub-authenticated user."
      )
    ]
  end

  defp e(entry_at, sha, category, summary) do
    %{entry_at: entry_at, sha: sha, category: category, summary: summary, visibility: "l2"}
  end
end
