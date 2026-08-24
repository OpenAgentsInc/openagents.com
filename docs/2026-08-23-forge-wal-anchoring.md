# Anchoring the forge WAL

**Date:** 2026-08-23
**Commit measured:** `7e5f7b1` on `openagents/main`, the forge
**Question:** `EXIT-002` proves the served repository can be checked against the WAL without trusting the operator's database, and its own conclusion is that the check is tamper-evident and not tamper-proof. What would make a *consistent* rewrite of the log detectable, what does each option really cost, and what can no option here achieve?
**Method:** direct reading of every writer of a WAL entry (`lib/openagents/forge/pushes.ex`, `lib/openagents/forge/git_plane.ex`, `lib/openagents/repositories/importer.ex`, `lib/openagents/repositories/provisioner.ex`), the log itself (`lib/openagents/forge/wal.ex` and its two adapters), the reader that replays it (`lib/openagents/forge/sync.ex`), the verifier (`lib/openagents/forge/verification.ex`), the derived receipt (`lib/openagents/forge/push_receipt.ex`), and the invariants they are bound to (`INVARIANTS.md`, `REPOSITORY-003`, `EXIT-001` through `EXIT-004`). Claims this repository cannot settle are in section 6 with what would settle them.
**Status:** Stages 1 and 4 shipped. Stages 2, 3, and 5 are open.

---

## 0. Summary

The WAL is the durable record of accepted pushes, and every part of it lives in
storage the operator controls. `OpenAgents.Forge.Verification` compares the
served repository against that record and reports five kinds of disagreement,
each of which is a disagreement *between two things the operator holds*. An
operator who edits both consistently leaves nothing behind to disagree with.

Anchoring is the name for fixing that, and it has exactly one shape: **a
commitment to the log's contents has to exist somewhere the operator does not
solely control, and each entry has to bind to its predecessor so a rewrite
cannot be confined to one entry.** The second half is local, cheap, and needed
by every version of the first half. The first half is a publication problem,
not a cryptography problem, and it is where the real cost is.

This commit ships the second half. Every entry appended to a WAL index now
carries a `"link"`: `sha256` over a domain tag, the previous entry's link, and a
canonical encoding of the entry's own fields (`lib/openagents/forge/wal.ex:269`).
`OpenAgents.Forge.Verification.verify/2` recomputes the chain and reports
`chain_link_mismatch` and `chain_link_missing`, and it accepts an `:anchor`
option — a `%{seq:, link:}` commitment the caller obtained somewhere other than
this log — and reports `anchor_mismatch` against it
(`lib/openagents/forge/verification.ex:90`).

What that buys, precisely: **a rewrite can no longer be local.** Changing any
accepted entry changes the link of every entry after it, so one remembered link
is enough to check the entire prefix of the log before it. Nothing in this forge
publishes such a link yet, so today the anchor is something a caller supplies.
The chain is the substrate that makes publishing one worth anything.

What it does not buy, stated as plainly: an operator who rewrites an entry, its
content-addressed key, the index, and every link after it produces a
self-consistent log, and `verify/2` with no anchor reports it clean. That case
is now a test rather than a caveat
(`test/openagents/forge/independence_test.exs`, "a consistent rewrite verifies
clean, and only an anchor reports it").

Three things follow from the analysis and are worth stating before the detail:

1. **Signing is the weaker option, not the stronger one**, because this
   deployment has nowhere to put a key that the operator does not also hold.
   Section 3.2.
2. **The pusher is the best-placed verifier there is**, because they already
   hold independent evidence of what they pushed — the commit SHAs in their own
   clone — and they are the party harmed by a rewrite. Returning them the head
   link at acknowledgment is the smallest step with a real beneficiary.
   Section 3.4.
3. **No anchor detects withholding.** An operator who serves nothing, serves
   stale state, or refuses a clone is not caught by any of this. Section 4.

---

## 1. What the WAL is today

### 1.1 The record

Each repository has one JSON index document and a set of immutable entry
objects, held by the adapter in `Application.get_env(:openagents,
:forge_wal_adapter)` — `OpenAgents.Forge.WAL.Local` by default
(`config/config.exs:298`), `OpenAgents.Forge.WAL.Gcs` in production, where
objects live under `forge/wal/<repo>/` in one bucket
(`config/config.exs:300`).

The index carries a version, an ordered `"entries"` list, and a top-level
`"refs"` map that is the post-state of the last entry
(`lib/openagents/forge/wal.ex:213`). Each entry carries `"seq"`, `"object"`,
`"format"`, `"refs"`, `"principal"`, and `"pushed_at"`; an import also carries
`"import_id"` and `"shallow"` (`lib/openagents/repositories/importer.ex:403`).

Two properties already hold and both matter here:

- **Entry keys are content-addressed.** `entry_key/2` is the zero-padded
  sequence plus the first 12 hex characters of the payload's `sha256`
  (`lib/openagents/forge/wal.ex:348`). Rewriting an accepted push's bytes
  without also rewriting the recorded key is detected.
- **The index advances by compare-and-swap on the storage generation.**
  `cas_index/3` (`lib/openagents/forge/wal.ex:93`) is the cluster-wide
  serialization point; in GCS it is `ifGenerationMatch`, so a stale writer gets
  `{:error, :cas_conflict}` rather than a lost update.

Neither property constrains a writer who holds the bucket.

### 1.2 The writers

Three production paths append an entry, and one creates an empty index:

| Path | Site | Entry format |
| --- | --- | --- |
| Push | `OpenAgents.Forge.Pushes.persist/4`, `lib/openagents/forge/pushes.ex:142` | `receive_pack` |
| Stack ref batch | `OpenAgents.Forge.GitPlane`, `lib/openagents/forge/git_plane.ex:513` | `git_bundle` or `ref_update` |
| GitHub import | `OpenAgents.Repositories.Importer`, `lib/openagents/repositories/importer.ex:403` | import payload |
| Empty repository | `OpenAgents.Repositories.Provisioner`, `lib/openagents/repositories/provisioner.ex:144` | none — index only |

Every one of them reaches the log through `WAL.append_entry/2`. That is the
seam this work uses: a chain computed anywhere else would cover pushes and
leave imports and stack operations outside it, and a log with holes in it is
not a chain.

### 1.3 The acknowledgment barrier

`handle_receive_pack/4` runs under a per-repository lock and acknowledges only
after the WAL takes the entry (`lib/openagents/forge/pushes.ex:46`). If the WAL
refuses, local refs are rolled back and the client sees a failed push
(`:100`). Everything after the barrier is derived and none of it can fail the
push: the receipt row (`:219`), the repository activity timestamp (`:123`,
which documents the reason), issue closing (`:267`, which runs inside `rescue`
and `catch` for exactly this reason, per `4651b3a`), the broadcast, and the
best-effort mirror.

This is the constraint that shapes the whole design. **Pushes are the most
load-bearing operation in this application**, and an anchor that can refuse one
is worse than no anchor. Any network call belongs after the barrier or off the
push path entirely.

### 1.4 The reader, and why per-entry integrity is the foundation

`2a678e7` (#103) changed replay to apply one entry at a time and move the refs
to the post-state that entry recorded before the next entry runs, because `git
receive-pack` re-runs push admission policy and a replay against the wrong ref
state is silently rejected with exit status 0
(`lib/openagents/forge/sync.ex:240`). `REPOSITORY-003` binds it
(`INVARIANTS.md:2759`).

The relevant consequence for anchoring is that **an entry is already a
self-contained, individually meaningful unit**: it names the objects it
introduces, it names the ref post-state it produces, and replay proves both
before advancing. A chain over entries therefore chains over something that
already has to be exactly right, rather than over an accounting artifact. If
entries were only meaningful in aggregate, a link over them would commit to
less than it appears to.

### 1.5 The derived receipt

`forge_pushes` rows are derived from the WAL and keyed by `{repo, wal_seq}`
(`lib/openagents/forge/push_receipt.ex:14`), and `reconcile_receipts/1`
re-derives every row from the entries after the table is emptied
(`lib/openagents/forge/pushes.ex:183`). Receipts are a projection, never a
second authority, and `EXIT-003` proves the direction. They are also in
PostgreSQL, which the operator holds, so they add little to detection — but
stage 4 stores the entry's link beside the receipt, which raises the cost of a
consistent rewrite from one store to two.

---

## 2. What an anchor has to be

The property wanted is: **someone who does not trust the operator can tell that
the log they are reading now is the log that accepted the pushes.** Three
things are needed and they are separable.

1. **A commitment.** A short value that identifies the log's contents, so that
   comparing two of them is cheap. A digest of the index would do; a chain head
   does better, for reason 2.
2. **Non-locality.** Each entry must bind to its predecessor, so that rewriting
   entry *k* invalidates every commitment taken after *k*. Without it, a
   commitment only covers the exact moment it was taken, and an anchor
   published hourly leaves every entry between anchors individually rewritable.
   With it, one commitment covers the entire prefix.
3. **External custody.** The commitment must be readable by the verifier from
   somewhere the operator does not solely control. This is the only part that
   cannot be solved inside this repository, and it is the whole difficulty.

Point 3 has a constraint the taxonomy already fixes: **GitHub is a mirror and
never authority** (`docs/taxonomy.md`). That rules GitHub out as a place where a
commitment could *decide* anything. It does not rule it out as a place where a
commitment could be *witnessed*, which is a different job — see section 3.3.

---

## 3. The options, with their true costs

### 3.1 A hash chain over entries, head published externally

**Shape.** Each entry records `link = H(domain ‖ previous_link ‖ canonical(entry))`.
A verifier recomputes the chain from any known link forward. Publishing the head
somewhere external turns the chain into a check anyone can run.

**What it detects.** Any modification, removal, reordering, or insertion at or
before a sequence for which someone holds a link — including the consistent
rewrite that defeats content addressing alone, because a consistent rewrite must
change every link after the rewritten entry, and the published one is not the
operator's to change.

**What it does not detect.** Anything after the last published link. Withholding.
An operator who never publishes, or who publishes only what they intend to keep.
Two forks of the log published to two audiences, unless the audiences compare
notes; that is the split-view problem, and only a single append-only publication
surface with third-party readers closes it.

**Cost per push.** One `sha256` over a few hundred bytes, in the same process,
inside a function that already runs. No I/O, no network, no schema change, no
new dependency. Measured against the `git receive-pack` invocation and the
object-storage round trips that dominate `persist/4`, it does not appear.

**What a verifier needs.** The log, and one link value obtained from anywhere
else. Nothing more — no key, no service, no clock.

**Verdict.** This is the substrate. Every other option is better with it and
weaker without it, and it costs almost nothing. Shipped in this commit as
stage 1.

### 3.2 Signing each entry with a key whose public half is published

**Shape.** The forge signs each entry, or each index generation, with a private
key. The public half is published. A verifier checks signatures.

**What it detects.** A rewrite by anyone who does not hold the private key.

**What it does not detect — and this is the objection that decides it.** A
rewrite by anyone who *does* hold the private key. The key has to be reachable
by the process that accepts pushes, which is the process the operator runs, on
the machine the operator controls, with its secrets in the operator's
environment. `docs/forge-operator-independence.md` already records that the
three existing hand-rolled vaults "take their key from the application
environment, which is the operator's environment. They defend against a stolen
database dump, not against the operator." A signing key on the push path is the
same shape. It would convert "the operator can rewrite the log" into "the
operator can rewrite the log, and it will still verify", which is worse than the
current honest position because it looks like a guarantee.

Signing becomes real only when the key lives somewhere the operator genuinely
cannot reach — an HSM with an append-only audit the operator does not
administer, or a key held by a party with an independent interest. That is not
a code change; it is an organizational change, and this repository should not
pretend otherwise.

**Cost per push.** One signature: for Ed25519, tens of microseconds and no I/O
if the key is in memory; a network call and a hard dependency on an external
service if it is not, which then sits on the push path and violates section 1.3
unless it is moved off it.

**What a verifier needs.** The public key, obtained from somewhere the operator
does not control — which is the same publication problem as 3.1, plus a key
custody problem 3.1 does not have.

**Verdict.** Strictly more machinery than 3.1 for a property that is weaker
under this threat model. Not recommended until custody changes. If it is ever
done, it should sign the chain head, not each entry, so the cost is per anchor
rather than per push.

### 3.3 Anchoring a periodic digest outside the deployment

**Shape.** A scheduled job publishes `{repo, entry count, head link, ref-map
digest, time}` somewhere external. A verifier fetches the last anchor and checks
the current log against it.

**What it detects.** Any rewrite of anything at or before the last anchored
sequence, given 3.1's chain. Without the chain, only a rewrite of the exact
state that was anchored, which is why 3.1 comes first.

**What it does not detect.** Everything after the last anchor — the exposure
window is the anchor interval. Withholding. Split views, unless the publication
surface is one that multiple parties read.

**Cost.** This is where the cost actually lives, and it is not per push:

| Surface | What it costs | What it is worth |
| --- | --- | --- |
| A commit to the GitHub mirror repository | Nothing new to build; `mirror_now/1` already exists but `:forge_mirror_urls` is empty (`config/config.exs:297`) and no mirror runs today | Weak but real: GitHub's own event history records a force push, and GitHub does not answer to this operator. It is witnessing, not authority, which keeps the taxonomy rule intact |
| A public append-only log with independent readers | Building or renting one, plus the operational duty to keep publishing | Strong, and it closes split views if the readers are plural |
| A timestamping authority or a public chain | An external dependency, a cost per anchor, and a key or account to manage | Strong on ordering and time, and it adds a party with no interest in this forge |
| The pusher's own machine (section 3.4) | Almost nothing | Strong for the party who cares most, weak for a third party |

**What a verifier needs.** The anchor's location and the ability to read it. No
key.

**Verdict.** Correct second step, and the cheapest useful version is the mirror
commit, precisely because it is already half-built. Staged as 3 and 5.

### 3.4 A client-side receipt returned to the pusher

**Shape.** At acknowledgment, return the pusher the sequence and the link their
push produced, in the `git receive-pack` report-status stream
(`lib/openagents/forge/git_http.ex:444`) or through a published receipts route.
The pusher keeps it.

**What it detects.** Any later rewrite at or before that sequence, checked by
the one party who already holds independent evidence of what they pushed and
who is harmed if it changes. This is the option the issue calls "the smallest
change that gives the affected party evidence they hold themselves", and the
analysis agrees.

**What it does not detect.** Anything a pusher does not keep. Anything about
repositories they do not push to. It also creates no obligation on the forge to
keep serving what it acknowledged.

**Cost per push.** Formatting a side-band line, after the WAL barrier. The
constraint is delicate rather than expensive: `git` clients treat an
unparseable report-status as a failure, so the line has to be a well-formed
side-band message, and any error while producing it must be caught and dropped
rather than propagated. That is the `4651b3a` pattern again.

**What a verifier needs.** Their own saved receipt, and `verify/2` with
`:anchor`, which exists now.

**Verdict.** The highest value per line of code after the chain itself, and it
depends on the chain. Staged as 2.

### 3.5 Summary table

| Option | Detects a consistent rewrite | Needs a key | Push-path cost | Verifier needs |
| --- | --- | --- | --- | --- |
| Content addressing alone (today) | No | No | None | The log |
| Hash chain, unpublished (stage 1) | No, but makes any rewrite total | No | One `sha256`, no I/O | The log, plus any remembered link |
| Chain + client receipt (stage 2) | Yes, for the pusher | No | One side-band line after the barrier | Their receipt |
| Chain + external anchor (stages 3, 5) | Yes, up to the last anchor | No | None — off the push path | The anchor's address |
| Signed entries | Yes, against a non-operator | Yes | Signature, or a network call | The public key |

---

## 4. What no anchor here can do

Stated with the same care `#94` used for its own limits, because an overclaim
about tamper detection is worse than the gap it papers over.

- **An anchor detects rewriting, not withholding.** An operator who deletes a
  repository, stops serving it, serves a stale copy, refuses a clone, or blocks
  one account still holds every one of those powers, and nothing in this
  document touches them. Availability is not integrity, and the honest framing
  is that anchoring tells you the history you *can* read is the history that was
  accepted.
- **An anchor cannot compel publication.** The operator chooses to publish.
  Stopping is indistinguishable from an outage until someone notices the silence,
  which is a monitoring property and not a cryptographic one.
- **An anchor cannot close a split view on its own.** Publishing one log to one
  reader and another to another is detected only when readers compare, or when
  the publication surface is single and public.
- **Nothing here constrains the operator.** `docs/forge-operator-independence.md`
  puts it correctly: what the invariants add "is not a constraint on the
  operator. It is the ability to *find out*." A chain and an anchor extend the
  reach of finding out. Neither prevents anything.
- **The chain does not authenticate the pusher.** `"principal"` is a string the
  forge writes, and a static shared forge token pushes as
  `operator:forge-token` with no attributable person behind it
  (`docs/forge-operator-independence.md`). Chaining a field does not make the
  field true; it makes it unrewritable-in-place.
- **Refs remain WAL-authoritative.** An anchor is evidence, never authority. A
  disagreement between an anchor and the log is a finding for a human, not an
  input to serving.

---

## 5. The staged path

Each stage names its seam and its size. Stages 2 through 5 are independent of
each other and all depend on stage 1.

### Stage 1 — Chain every entry to its predecessor (this repository, small) — SHIPPED

**Seam:** `WAL.append_entry/2` (`lib/openagents/forge/wal.ex:213`), the single
function every writer reaches the log through, plus
`OpenAgents.Forge.Verification` for the reading side.

`chain_link/2` (`:269`) computes `sha256` over a domain tag, the previous
entry's link, and a canonical encoding of the entry's fields. The encoding is
its own function (`:300`) rather than JSON, because encoders disagree about key
order and this digest has to survive being written by one release and
recomputed by another; every value carries its own length or terminator, so no
two distinct entries encode alike. The encoding is pinned by a golden vector,
because every link ever written depends on it and a refactor that changed it
would turn every existing log into apparent tampering. Sorting the map keys is
defensive rather than proven: equal maps iterate identically in this runtime,
so no test in this repository can distinguish sorted from unsorted, and the
mutation check for it came back green — recorded here rather than claimed as
covered. `verify/2` recomputes the chain, reports `chain_link_mismatch` and
`chain_link_missing`, exposes `:head` and `:chained_from`, and accepts an
`:anchor`. `EXIT-005` binds it.

**Why it cannot fail a push:** the link is derived from data already in hand,
with no I/O, by a function that is total by construction — the last clause of
the canonical encoder accepts any term — and the derivation is additionally
wrapped so that a link which cannot be produced is *omitted* rather than
raised (`:287`). An entry then goes into the log unchained and the verifier
reports `chain_link_missing`, which is a thing to find out about rather than a
reason to refuse a push the forge is able to accept.

### Stage 2 — Return the link to the pusher (this repository, small)

**Seam:** the report-status assembly in `OpenAgents.Forge.GitHTTP`
(`lib/openagents/forge/git_http.ex:444`) and the acknowledgment path in
`Pushes.do_handle/5` (`lib/openagents/forge/pushes.ex:52`), strictly after the
WAL barrier, inside `rescue` and `catch`.

Emit one side-band informational line carrying the repository, the sequence, and
the link. Publish a receipts route so a pusher can fetch it later; `EXIT-001`
currently records `push_receipt` as `blocked` because no published route serves
receipts, so this stage moves that ledger row as a side effect. The invariant to
amend is `EXIT-001`, and the ledger probe makes the change fail closed if the
row is not updated.

**Size:** small. **Risk:** the side-band format — it must be exercised against
the real `git` client, which `test/openagents/forge/independence_test.exs`
already does.

### Stage 3 — Publish the head where the operator does not solely control it (this repository, medium)

**Seam:** a scheduled job beside `OpenAgents.Forge.MirrorWatch`, never on the
push path.

Publish `{repo, entries, head link, ref-map digest, published_at}` on an
interval. The cheapest surface with a real third party is a commit to the GitHub
mirror, which keeps GitHub as a witness and not as authority; `:forge_mirror_urls`
is empty today (`config/config.exs:297`), so this stage has to configure a
mirror before it can use one. A second surface with independent readers is
strictly better and is the stage 5 question.

**Size:** medium, mostly operational. **What it settles:** everything at or
before the last published head becomes checkable by a stranger.

### Stage 4 — Store the link beside the derived receipt (this repository, small) — SHIPPED

**Seam:** `forge_pushes` (`lib/openagents/forge/push_receipt.ex`) and
`reconcile_receipts/1` (`lib/openagents/forge/pushes.ex`).

`20260824010826_add_chain_link_to_forge_pushes.exs` adds a nullable `link`
column. The live push path writes it from the entry the WAL just accepted, and
`reconcile_receipts/1` re-derives it from the entries, so the column is a
projection in both directions and never a second opinion about the chain. The
admin forge panel renders it beside the sequence it belongs to.

This is weak on its own — PostgreSQL is the operator's too — and the honest
statement of what it buys is that a consistent rewrite now has to edit object
storage and PostgreSQL together rather than object storage alone. The proof
rewrites every stored link to a value the log never produced and asserts that
verification is unmoved, because the verifier recomputes the chain from the WAL
and reaches no database.

Rows written before the column carry no link and are not repaired in place. A
row whose entry predates the chain has no link to carry, and writing one over
entries the operator holds is the backfill section 7 rules out.

**Size:** small, but it is a migration, so `RELEASE-001` applies.

### Stage 5 — Decide the durable publication surface (open question, large)

**Seam:** none in this repository yet.

Choosing between a self-run append-only log, a third-party timestamping service,
and a public chain is a cost and custody decision, not an implementation one.
Section 6 lists what would settle it. Until it is settled, stage 3's mirror
commit is the honest interim: witnessed, cheap, and not overstated.

---

## 6. What this repository cannot settle

- **Where the anchor should live.** The options differ in cost, in who reads
  them, and in what happens when publication stops. Settling it needs a decision
  about who the verifier is expected to be — a pusher, a user, or an auditor —
  and only the first is served by stage 2 alone.
- **Whether the operator will accept a custody split.** Signing is only worth
  building after that answer, and the answer is not a code change.
- **What the production logs actually contain.** Every claim here about existing
  entries is derived from the code that writes them, which is sound for a field
  that did not exist until this commit. A direct read of the production bucket
  would confirm the entry counts per repository and is the one measurement this
  document does not have.
- **Whether the canonical encoding is stable across runtimes.** It is pinned by
  a golden vector against the runtime this repository builds on. A change in
  BEAM map iteration or in float formatting would be caught by that vector on
  the next build, which is detection rather than prevention, and the recovery
  would be to keep the old encoding for entries already linked under it.

---

## 7. What happens to entries already written

Every entry in every log today carries no `"link"`, because
`WAL.append_entry/2` is the only writer of an entry and the field is new in
this commit. Unlike `2a678e7`, which found that no backfill was needed because
every production entry already carried what its change required, **no backfill
is possible here, and that is the correct outcome rather than a limitation.**
A backfilled link would be the operator computing a commitment over entries the
operator holds, at a time of the operator's choosing, which proves exactly
nothing. Anchoring is only meaningful forward from the moment a commitment
leaves the operator's storage.

So the boundary is explicit and the verifier reports it rather than hiding it:

- `verify/2` returns `:chained_from`, the first sequence carrying a link.
  Entries before it predate the chain and are not covered by it.
- An entry with no link is a finding (`chain_link_missing`) **only** when an
  earlier entry has one. A chain that stops in the middle of the log is
  tampering; a chain that starts in the middle is history.
- The first entry appended after this deploys binds to the chain start `""`,
  because its predecessor has no link to name
  (`lib/openagents/forge/wal.ex:247`).
- Verification for those earlier entries stays what it was: content addressing,
  sequence contiguity, ref agreement, and object presence. Best-effort against a
  consistent rewrite, exactly as `EXIT-002` said.

One consequence deserves stating because it is the obvious attack: an operator
could strip every link and claim the whole log predates the chain. Nothing
inside the operator's storage refutes that. What refutes it is a single link
held outside — which is stage 2 and stage 3, and is why stage 1 is a substrate
and not a property.

---

## 8. Invariants touched

| Invariant | Change |
| --- | --- |
| `EXIT-002` | Amended. The caveat now names the chain, says what it does and does not add, and points here for the publication that would close it. |
| `EXIT-005` | New. Every WAL entry commits to the entry before it, and the chain is checkable against an externally held link. Proof: `test/openagents/forge/independence_test.exs` and `test/openagents/forge/wal_test.exs`. |
| `REPOSITORY-003` | Unchanged, and load-bearing. Replay reads entries one at a time against the ref state each recorded, which is what makes an entry an individually meaningful unit worth chaining. |
| `EXIT-003` | Amended by stage 4. The receipt now carries the entry's link, still derived from the WAL in both directions, and the proof shows a rewritten stored link changing no verification outcome. |
| `EXIT-001` | Untouched by stage 1 or 4. Stage 2 moves its `push_receipt` row from `blocked`. |
