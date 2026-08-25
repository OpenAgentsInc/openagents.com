# Issues: Persistent Agent Continuity & Epistemic Memory System

### Issue #1: Formal Engram Schema (NIP-AE Companion Profile) & Redaction Invariants
**Target:** `openagents` (`packages/agent-experience-memory`), `openagents.com`
**Type:** Specification & Core Invariants
**Labels:** `agent-ready`, `memory`, `security`

**Description:**
Establish the formal data structures and security guarantees for durable episodic memory events (engrams).
1. Define the OpenAgents companion profile for NIP-AE `kind:30174` addressable events.
2. Implement strict zero-credential / zero-secret redaction filters (tokens, private SSH/Nostr keys, private IPs, environment variables) that run strictly *prior* to engram signing.
3. Define the explicit supersession model: memories are immutable once signed; corrections append new engrams that explicitly reference and supersede previous event IDs.

**Acceptance Criteria:**
- Redaction test suite passing with 100% catch rate on synthetic tokens/secrets.
- Engram signature and supersession chain verification unit tests.

---

### Issue #2: Engram Client & Relay Sync Adapter in Agent SDK
**Target:** `openagents` (`packages/agent-experience-memory`)
**Type:** Feature
**Labels:** `agent-ready`, `sdk`, `nostr`

**Description:**
Implement the engram sync provider within `@openagentsinc/agent-experience-memory`.
1. Provide signing, symmetric encryption (scoped to owner conversation keys), and transport over Nostr relays.
2. Implement optimistic caching and background dispatch so engram persistence is completely non-blocking to interactive user turns.
3. Add degraded-mode resilience: turns proceed gracefully if the memory relay is unreachable.

**Acceptance Criteria:**
- SDK passes end-to-end integration test publishing encrypted engrams to a local relay.
- Synthetic network outage test confirms zero latency penalty or failure on agent turns.

---

### Issue #3: Deterministic Graph & Embedding Projection Worker
**Target:** `openagents.com` / `openagents`
**Type:** Feature
**Labels:** `agent-ready`, `indexer`, `cognee`

**Description:**
Build the projection layer that converts the append-only cryptographic engram log into a queryable semantic graph and vector index.
1. Ingest NIP-AE engrams from relay/storage and derive relational entities, attributes, and vector embeddings.
2. Ensure the projection layer is strictly ephemeral/derived: build an idempotent replay tool capable of cold-starting and regenerating the complete index from raw engram history.

**Acceptance Criteria:**
- Replay test takes raw engram stream and reconstructs an identical graph index.
- Conflicting/superseded engrams correctly invalidate stale nodes in the projection.

---

### Issue #4: Background Autonomous Consolidation ("Dreaming Loop")
**Target:** `openagents.com` (`OpenAgents.Memory.Consolidation`)
**Type:** Feature
**Labels:** `agent-ready`, `ai-research`, `background-jobs`

**Description:**
Build an asynchronous background worker that periodically reviews episodic engrams to synthesize high-level heuristics and lessons learned.
1. Identify fragmented episodic experiences across different sessions and cluster them by concept/topic.
2. Detect contradictions or outdated assumptions, proposing superseding synthesis engrams.
3. Compress multi-turn workflows into persistent heuristics (e.g., "when working on Phoenix routes in this repo, ensure reloader state is checked").

**Acceptance Criteria:**
- Background worker processes synthetic cluster of 20 episodic engrams into a single concise heuristic engram.
- Provenance links point back to source episodic engrams.

---

### Issue #5: Memory Evolution & Consent LiveView Dashboard
**Target:** `openagents.com` (`OpenAgentsWeb.MemoryLive`)
**Type:** UI / UX & Consent
**Labels:** `agent-ready`, `liveview`, `ui`

**Description:**
Provide an operator interface at `/memory` for auditing, inspecting, and managing persistent agent memory.
1. Visualize active memory graph, recent engrams, and derived heuristics.
2. Show full audit trail of supersessions and corrections.
3. Provide one-click retraction/forgetting tools that append cryptographically signed deletion/tombstone receipts.

**Acceptance Criteria:**
- LiveView renders memory timeline and graph nodes.
- Operator can view superseded history and trigger explicit memory redaction/tombstones.

---

### Issue #6: Scoped Memory Inheritance for Subagent Delegation
**Target:** `openagents` (`packages/openagents-cli/src/delegate`)
**Type:** Feature
**Labels:** `agent-ready`, `coder`, `delegate`

**Description:**
Enable child agents spawned via `delegate` (Devin, ox-alpha, gemini, etc.) to inherit relevant parent memory without leaking global context or credentials.
1. When `delegate` is invoked, query the parent memory graph for task-relevant heuristics based on the child's prompt.
2. Inject a sanitized "Epistemic Context" block into the child agent bootstrap prompt.
3. Ensure no private keys, conversation-private engrams, or unrelated session state leak to the subagent harness.

**Acceptance Criteria:**
- Child prompt includes relevant repository heuristics derived from previous sessions.
- Zero credential leakage confirmed by automated scanner.

---

### Issue #7: Child Engram Harvest & Parent Ledger Re-integration
**Target:** `openagents` (`packages/openagents-cli/src/delegate`)
**Type:** Feature
**Labels:** `agent-ready`, `coder`, `delegate`

**Description:**
Close the delegation loop by automatically harvesting discoveries, changes, and verification receipts from child agents and committing them to the parent agent's memory ledger.
1. Parse child execution artifacts, logs, and receipts upon task completion.
2. Construct and sign new episodic engrams representing the child's verified findings and diffs.
3. Publish engrams to the parent agent's stream so subsequent turns and sessions benefit from the subagent's work.

**Acceptance Criteria:**
- Parent memory graph reflects subagent's findings immediately after child completes.
- Trace receipts link child process run to newly created engrams.

---

### Issue #8: Unified Multimodal Activity Stream & Context Continuity
**Target:** `openagents.com` (`OpenAgents.Voice`, `OpenAgents.Chat`)
**Type:** Feature
**Labels:** `agent-ready`, `multimodal`, `voice`

**Description:**
Unify memory and activity context across modalities (Voice, CLI terminal sessions, Web LiveView chat).
1. Merge voice tool execution steps, CLI coder events, and LiveView text turns into a unified timeline schema.
2. Ensure switching between speaking on voice, coding in terminal, and reviewing on web shares the exact same active memory state and context window.

**Acceptance Criteria:**
- Conversation begun on voice can be continued seamlessly in CLI coder with full context recall.
- Ordered tool steps from all modalities display in a unified transcript view.
