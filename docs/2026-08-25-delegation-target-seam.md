# The delegation target seam

**Date:** 2026-08-25
**Issue:** [#37](https://openagents.com/OpenAgentsInc/openagents.com/issues/37), *Integrate cloud computers with Work, chat, text, voice, and API*
**Source:** `docs/2026-08-22-cloud-computer-scale-architecture-audit.md`
**Status:** The seam in section 4 shipped with this document. Sections 5 and 6 are the decisions it defers.

Issue #37 asks for five integrations: Work, chat, text, voice, and the
authenticated API. This document argues they are one integration and four
renderings, names the part they share, and records what shipped.

---

## 1. "Cloud computer" is not a noun this codebase gets

`docs/taxonomy.md` already settled the word, and #37 collides with it:

> **computer** — someone's own machine, connected or absent, never provisioned
> **box** — a sandbox VM this application provisions, caps, and reclaims

So an OpenAgents-managed cloud computer cannot be called a computer here. It is
a **Box**, and #37's "customer-connected computer" is a **Computer**. The
delegation target kind is already `box` or `computer`, the kind already travels
in the identifier (`box:{uuid}`, `computer:{uuid}`), and authority is already
scoped per kind.

Adding a third kind named `cloud_computer` would create exactly the collision
the taxonomy exists to prevent: three nouns, two of which are provisioned, one
of which is not, and a reader who cannot tell from the name which failure a
missing one is. A Box that is gone was reclaimed and you can provision another.
A Computer that is gone is somebody's laptop.

**Decision.** #37 adds no target kind. It makes the two that exist addressable,
observable, and advertisable through one seam.

---

## 2. What exists today

Measured by direct reading, not by documentation.

**Real, in this repository:**

| Thing | Where | What it does |
| --- | --- | --- |
| Delegation facade | `OpenAgents.Delegations` | One `start` / `get` / `cancel` / `inventory` across both kinds, at `/api/v1/conversations/{id}/delegations`. Stores nothing; derives everything. IDENTITY-009. |
| Box substrate | `OpenAgents.Box`, `OpenAgents.BoxRuns` | Rents VMs from the Box Public API at `ascii.dev`. Ledgers `conversation_boxes`, `box_runs`, `box_fanout_items`. |
| Computer substrate | `OpenAgents.Machines`, `OpenAgents.Computer`, `OpenAgents.ComputerAgentJobs` | Pairing, credential, live WebSocket control, durable ACP delegations as `work_jobs` rows. |
| Capacity and matching | `OpenAgents.Capacity` | Runtime classes `standard`, `strong`, `batch`, `connected`, each with an isolation, egress, and data location. Published at `/api/v1/capacity` and `/api/v1/capacity/matches`. Issue #76. |

**Documented, and not real anywhere:**

- The logical-computer record, the runtime-lease record, and the command
  journal with `may_have_started`. None exists in this repository.
- The provider-neutral control-plane `Req` client #37 asks for. **There is no
  endpoint for it to call.** In the `OpenAgentsInc/openagents` monorepo,
  `crates/openagents-cloud-contract/src/cloud_computer_v1.rs` and the 34-file
  `packages/khala-sync-server/src/cloud-computer-*.ts` set are real, tested
  code that no binary imports and no route exposes; there are no fixtures for
  `cloud_computer.v1` and no OpenAPI, protobuf, or JSON schema describing any
  cloud-computer request or response. The one machine-readable artifact,
  `schema/cloud_computer.v1.schema.json`, describes a record, not an endpoint.

That last finding decides the shape of this work. A `Req` client written today
would be a client for something that does not answer.

---

## 3. The seam, and why five surfaces share exactly one

Work, chat, text, voice, and the API differ in who is asking and how the answer
is drawn. They ask the same three questions of a target:

1. **How is it addressed?** By the kind-prefixed reference the facade already
   parses. Settled, and nothing here mints a second identifier.
2. **What is it doing?** Today, four vocabularies answer this and none of them
   agree. `conversation_boxes.state` has ten values; `box_runs.state` has eight;
   `work_jobs.status` has seven; a Computer has `status` plus a live
   reachability read. A surface that wants to say "this computer is busy" must
   know all four.
3. **What may this caller do to it?** Nothing answered this at all. Every
   surface had to re-derive it from kind, state, and scopes.

The third question is the one that earns a module. Reach is scoped per kind
(IDENTITY-009), so a surface that decides for itself whether a caller may start
work on a target is a surface that can widen reach past the substrate. Five
surfaces means five chances to get that wrong, and four of them would be
written by someone reading the fifth.

Before this change there were also three divergent projections of "what can I
delegate to": the `computer_list` tool's own result schema, which cannot see a
Box at all; the API's `openagents.delegation_targets.v1`; and the chat panel's
fleet projection. Three answers to one question.

---

## 4. What shipped

`OpenAgents.Delegations.Target` — pure, no database, no process — computes five
fields for any target, and two for any delegation.

| Field | Meaning |
| --- | --- |
| `custody` | `openagents_managed` or `customer_premises`, **derived from the target kind alone**. |
| `runtime_class` | The `OpenAgents.Capacity.Catalog` class, or `nil` when none describes the kind. |
| `lifecycle` | One word from the seven-state enum of `openagents.cloud_computer.v1`. |
| `capabilities` | The operations this caller may exercise now. `["start"]` or `[]`. |
| `unavailable_reason` | The lifecycle when the target is not startable, `not_authorized` when authority is what is missing, `nil` when nothing is. |

A delegation carries `lifecycle` from a six-word vocabulary and
`capabilities` of `["cancel"]` or `[]`.

Three decisions inside it are worth stating.

**Custody is structural.** It reads the target kind and nothing else. It cannot
be reached from the route that received the request, from whether the caller
typed or spoke, or from anything about the asking. This is what makes #37's
acceptance criterion — *never infer customer-owned versus OpenAgents-managed
from text versus voice or from the route* — a property of the type rather than
a rule five surfaces must remember.

**The lifecycle vocabulary is borrowed, not invented.** The seven words are the
`state` enum of `openagents.cloud_computer.v1` verbatim. The Elixir projection
maps onto the contract that already exists upstream, so a target described here
keeps its word if a control plane ever starts producing one. The substrate's own
state travels beside it untouched, because the substrate is still the authority
and this is a projection of it.

**A Box claims no runtime class.** `Capacity.Catalog`'s `standard` class asserts
`policy_broker` egress and `managed_standard` isolation. A Box is rented from a
third party and nothing in this repository establishes its egress posture, so
calling it `standard` would publish a containment claim no test backs.
`runtime_class("box")` returns `nil` until that evidence exists. A Computer is
`connected` by construction, and `Capacity.Connected` already counts machines as
that class.

The tests derive their inputs from the substrate schemas rather than listing
them: every value of `ConversationBox.states/0`, `Run.states/0`, and
`Job.statuses/0` must map into the vocabulary, and a new state fails the suite
the day it lands instead of silently reading as `failed` on five surfaces. The
authority tests assert the negative case for every kind and lifecycle pair, so
a capability cannot leak by omission.

Both consumers now read it: `Delegations.inventory/2` for the API, and
`Delegations.projection/2` for the chat panel, including the fan-out queue —
which is the only thing in this application that reaches the contract's
`queued` state today.

---

## 5. Why the remaining surfaces are a rendering, not four integrations

**Chat and #38.** #38 wants each logical computer shown with a stable label and
one of `cold | queued | starting | active | stopping | failed | destroyed`, the
reason a computer is queued, and owner controls "only when the current
capability allows them". Those are `lifecycle`, `unavailable_reason`, and
`capabilities` on a projection the chat panel already receives. #38 is a
template and a set of tests over fields that now exist.

**Text and voice.** Both already reach the same `OpenAgents.Work` path;
`work_jobs.surface` is `text` or `voice` and nothing else about the two differs.
Because custody is derived from the target kind, the equivalence #37 demands —
that a text and a voice request produce the same target, authority, and custody
— holds by construction rather than by a test that watches for drift.

**The API.** Already served. The seam is additive on
`openagents.delegation_targets.v1`.

**Model tools.** A tool renders the same document. It is deliberately not
shipped here: the tool catalog is at a **zero base** by policy
(`docs/2026-08-23-agent-tools-zero-base.md`), seven read-only tools ship, and
none of the five computer tools is among them. Re-admission runs through that
document's six criteria and is a change to both `config/config.exs` and
`shipped_catalog_test.exs`. #37's line about adding a model tool predates that
policy. The seam is built so re-admitting one is a config line and a rendering;
the admission decision belongs to section 6 of that document, not to this issue.

**Work.** `Capacity.match/2` returns a runtime *class* and never a thing you can
address; `Delegations` returns addressable targets and, until now, no class.
A surface that wanted to choose a target had to bridge those itself. The
descriptor is that bridge's near half. The far half is section 6.

---

## 6. What this does not do

Named plainly so nothing here reads as more than it is.

- **No control-plane client.** There is no endpoint. Section 2.
- **No logical-computer or runtime-lease record**, no generation fence, no
  command journal, and so no `may_have_started`. #37's recovery criterion is
  unmet and stays unmet until those exist upstream.
- **No Box capacity evidence.** `OpenAgents.Capacity` counts connected
  computers and broker-reported managed classes. It cannot see a Box — the one
  OpenAgents-managed compute this application actually provisions. Closing that
  loop means classifying the Box's isolation and egress, which is the decision
  `runtime_class("box") == nil` is holding open.
- **No new operations.** `start` and `cancel` are what the facade serves, so
  they are what it advertises. #37's `attach`, `stop`, `checkpoint`, `restore`,
  `fork`, and `destroy` are not capabilities this seam can honestly offer, and
  a capability list that names operations no route serves is worse than none.
  A Box can in fact be stopped, but only through `Fleet.stop/2` by label, on a
  path the facade does not own.
