# Project: Persistent Agent Continuity & Epistemic Memory System

## Overview
A comprehensive architecture and implementation plan for continuous agent memory, self-consolidation ("dreaming/consolidation" loop), epistemic heritage for delegated subagents, and cryptographic engram storage.

This project synthesizes the core principles of the Sarah architecture (Nostr NIP-AE signed engrams + rebuildable Cognee graph projection) with proactive memory consolidation and cross-agent shared heritage.

## Target Repositories & Modules
- `openagents.com`: LiveView memory management, Phoenix backend engram/projection sync, voice/text unified timeline.
- `openagents` (`packages/agent-experience-memory`, `packages/openagents-cli`): Core SDK memory adapters, CLI projection queries, delegate memory inheritance.

---

## Work Breakdown Structure & Issues

### Phase 1: Cryptographic Engram Ledger & Rebuildable Graph
- **Issue 1: [Spec & Invariants] Formal Engram Schema (NIP-AE Companion Profile) and Redaction Invariants**
  - Define schema for signed, encrypted kind:30174 events.
  - Implement zero-credential redaction pipeline before engram generation.
  - Specify supersession rules (corrections supersede rather than overwrite).
- **Issue 2: [SDK] `@openagentsinc/agent-experience-memory` Engram Client & Sync Provider**
  - Implement signed engram serialization, encryption, and sync to Nostr/Khala relay.
  - Ensure failure resilience (memory offline does not block the active conversation turn).
- **Issue 3: [Projection] Asynchronous Graph Indexer (Cognee / Vector + Relational)**
  - Implement deterministic graph projection worker replaying engram stream.
  - Support cold-start full rebuilds from raw engram history.

### Phase 2: Autonomous Memory Consolidation ("Dreaming Loop")
- **Issue 4: [Background Worker] Asynchronous Memory Synthesizer & Heuristic Compressor**
  - Periodic / idle background job evaluating recent episodic engrams.
  - Detects contradictions, clusters related episodic memories, and derives high-level behavioral heuristics.
  - Emits consolidated memory engrams linked back to parent sources.
- **Issue 5: [Consent & Audit] Memory Evolution Dashboard & supersession History**
  - LiveView UI in `openagents.com/memory` showing active graph, engram ledger, and derived heuristics.
  - Manual verification, correction, and consent retraction controls for the operator.

### Phase 3: Epistemic Lineage & Delegated Agent Memory
- **Issue 6: [Harness] Scoped Parent Memory Projection for `delegate` Tool**
  - When spawning child harnesses (`devin`, `ox-alpha`, `gemini`), package relevant memory heuristics into the child's bootstrap context.
  - Filter out parent secrets and irrelevant global states.
- **Issue 7: [Receipts] Child Engram Harvest & Parent Ledger Re-integration**
  - Collect structured findings and receipts from completed child agents.
  - Automatically sign and commit child discoveries as new engrams on the parent agent's ledger.

### Phase 4: Multimodal & Cross-Harness Continuity
- **Issue 8: [Unified Stream] Cross-Modality Timeline (Voice, CLI, Web, Agent-to-Agent)**
  - Unify voice tool step logs, CLI coder events, and LiveView chat messages into a single timeline stream.
  - Seamless context carry-over across UI, terminal, and speech interactions.
