# Forge operator independence and exit

This forge is run by one operator. This page says what that operator can do,
what they can see, what you have to take on trust, and which of those things
are now bound by an executable invariant instead of by intent.

`docs/episode-triage.md` reduces the product thesis to three testable
properties. The third is that authority stays inspectable at every boundary and
that exit is always possible. The forge is the substrate the rest of the
product sits on, so if you cannot get your work out and check it without asking
the operator, transparency here is a claim rather than a property.

An accurate description of a single-operator system is more useful than an
aspirational description of a federated one, so nothing below is softened.

## The trust boundary today

### One operator, and what defines one

Operator identity is an allowlist of GitHub's immutable numeric account IDs.
`OpenAgents.Accounts.admin?/1` matches on that ID, never on a login, and the
list is one hardcoded ID plus whatever `OPENAGENTS_ADMIN_GITHUB_IDS` adds.
There is no role table, no scoped operator, no separation of duties, and no
second signature on anything. Every allowlisted ID holds the same authority as
every other.

### What the operator can do

- **Accept any push.** `OpenAgentsWeb.Plugs.ForgeGitAuth` resolves an HTTP
  Basic password into a user token, a machine token, an assignment credential,
  or one static forge operator token read from the environment. That last
  principal passes `OpenAgents.Forge.GitHTTP`'s authorization with read and
  write on every repository the node is configured to serve, with no membership
  check. It is a single shared string, so a push it makes is recorded against
  the principal `operator:forge-token` and is not attributable to a person.
- **Promote a deployment.** `OpenAgents.Forge.Targets.promote/4` is reachable
  only from the operator forge panel, and only for a commit the WAL already
  holds, so the panel cannot introduce code. That bound is real and it does not
  separate duties: the same person holds the token that put the commit in the
  WAL.
- **Set what the world sees.** `OpenAgents.Forge.Visibility` reads a
  repository's transparency tier from application configuration and never from
  request data, so raising a repository from `dark` through `pulse` and `ledger`
  to `glass` ships through the receipted deploy pipeline rather than through a
  button. The operator owns that configuration.
- **Write through several product surfaces.** Deployment starts, Codex account
  connection, forum moderation, identity-claim review, agent suspension,
  artifact listings, and continual-learning jobs are operator writes today.
  `ADMIN-001` enumerates each of them by route, and
  `test/openagents_web/operator_surface_test.exs` compares that enumeration
  against the router and against every module that consults
  `OpenAgents.Accounts.admin?/1`, so a new operator write cannot land without
  amending the invariant. None of them reaches an account row, a conversation,
  a message, or a ban.

### What the operator can see

- **Every account.** `OpenAgents.Admin` reads the account roster with display
  identity, status, join and last-authentication times, and message and issue
  counts.
- **Recorded call audio.** `OpenAgentsWeb.AdminRecordingController` unseals and
  streams any account's call recording at `GET /admin/recordings/:id/audio`. The
  privacy copy in the product says so, and `ADMIN-001` now names the route
  rather than denying it.
- **Everything in PostgreSQL.** There are no encrypted Ecto column types
  anywhere in this application. Issue bodies, comments, conversation messages,
  repository metadata, and every receipt family are stored as plaintext. Three
  hand-rolled vaults seal three specific fields — GitHub access tokens, machine
  pairing tokens, and voice recording chunks — and each takes its key from the
  application environment, which is the operator's environment. They defend
  against a stolen database dump, not against the operator.
- **Every repository's contents.** Git objects live unencrypted in the node's
  bare repositories and in the WAL. Whatever protection exists is disk-level
  and object-storage-level, which is to say transparent to whoever runs the
  node.

None of these reads is audited. There is no record of which accounts or which
recordings an operator opened, and `ADMIN-001` records that absence as a
decision rather than an oversight. An access log written by the operator's
application into the operator's database is evidence to the operator and to
nobody else, so it would read as a control while constraining nothing. Making
the read accountable needs the same signature or external anchor the WAL lacks,
which is issue #151.

### What you take on trust

Everything above. The controls in this repository are careful about keeping
*tenants* apart from each other — a deployment principal typed as operator is
refused as a tenant, assignment credentials are digest-only and scoped to one
ref, visibility is never derived from a request — and not one of them
constrains the operator from the users of their own forge. You are trusting
that the operator does not read what they can read, does not push what they can
push, and does not rewrite what they can rewrite.

What the invariants below add is not a constraint on the operator. It is the
ability to *find out*: to check the served repository against the log that
accepted it, to rebuild from that log without the operator's database, and to
leave with a complete copy.

## Export

The question is what "your data" means here concretely, and the answer is
uneven enough that it deserves a ledger rather than a sentence.

`OpenAgents.DataRights.ExportInventory` is that ledger. It classifies every
resource family the API publishes, plus the families that leave through routes
outside `/api/v1`, into four statuses:

| Status | Meaning |
| --- | --- |
| `portable` | A published mechanism returns the family's records to the account that owns them, and a named proof shows it. |
| `partial` | Published reads reach the records, and nothing yet proves an account gets its own records back. No account-scoped export exists. |
| `blocked` | The account cannot read its own records through any published route. Probed, not assumed. |
| `not_user_data` | The family carries no record a user authors and takes with them. |

The ledger is deliberately pessimistic. A family stays `partial` until someone
writes the proof, because `docs/taxonomy.md` naming rule 7 is that an invariant
is not true until its proof runs green, and an unproven portability claim is
the same kind of claim.

What is proven portable today:

- **Repository content.** An `oa_pat_` token with the `forge:write` scope
  clones a private repository over the authenticated Git transport. The clone
  is complete and re-serves without the forge, which is `EXIT-004`.
- **Issues, projects, and the repository list.** These resolve through
  `OpenAgents.Repositories`'s visibility predicate, so a member reads them for
  a private repository.
- **Issue metadata.** Comments, labels, milestones, assignees, issue labels,
  and issue assignees resolve through the same predicate as of 2026-08-23, so
  a member reads their own private repository's issue records. Until then a
  public-only query answered `404` to the repository's own owner, which issue
  #142 closed.
- **Conversations, memory, and voice disclosure.** `GET /data/export`,
  `GET /data/export/atif`, and `GET /memory/export`, under `DATA-004`. That
  export is scoped to the account's one conversation with the agent, and it
  carries the account chat backend's runs and event stream alongside messages,
  memory, voice, and tool steps.
- **Forum posts and topics, threads and their transcripts, push receipts,
  deployment requests and approvals, Box leases and runs, paired computers, and
  agent links.** `GET /data/export/account`, an account-scoped document
  published alongside the conversation export rather than inside it. Every
  collection states its cap and reports its own truncation. Adding
  `?recipient=age1…` returns the same document encrypted to a key you
  generated and this forge never sees (#178).
- **Pull requests, stacks, and issue dependencies.** The same document's
  `repository_work` section, which is the one read on this surface that crosses
  repositories. Enumeration was the easy half: the read filters on the column
  that names the authoring account and joins
  `OpenAgents.Repositories.readable_by/2`, the predicate every per-repository
  read composes, so a record the account authored in a repository it can no
  longer read is withheld and no private repository the account never belonged
  to is reached. Stack boundary object ids travel here even though the
  `refs/internal/` namespace holding them is not advertised to a clone.

Nothing is blocked today, which is a result rather than a default. Issue #142
opened the private-repository metadata reads and #143 exported the forge-owned
and forum-owned families; before those, a private repository answered `404` to
its own owner and push receipts left through no route at all. The ledger keeps
the `blocked` status and its shape checks, because the honest move when a
family becomes unreadable is to record it.

Nothing is `partial` today either, and reputation attestations were the last
family to move. Issue #165 could not move them, and the reason was never
enumeration: an attestation names its subject with a bare string the issuer
supplies, so what was missing was a binding rather than a query. Issue #171
added it. `reputation_subject_claims` resolves a subject the way
`forum_actor_links` resolves a legacy forum identity — a claim you make, an
operator decides, and only a `linked` claim resolves — and its unique index on
`subject_id` means one subject never resolves to two accounts. The attestations
travel under `repository_work` behind the same `readable_by/2` join the other
repository-keyed families use, and the `repository` and `private` transparency
tiers stay behind the same membership test the API applies, so a wider export
never means wider disclosure.

Who owns a migrated forum post is the subtle question in the account export,
and it is answered rather than assumed. Two identities resolve to an account:
`user:<account-id>`, which every topic and post written on this surface
carries, and any `actor_ref` the account holds a `linked` claim on. A post
written under a legacy identity nobody has claimed, or whose claim is still
pending or was rejected, is **not** exported — the display name may make the
authorship obvious to a reader, but nothing has established it, and an export
that guessed wider would hand one account another account's writing. The claims
travel in the document at every status, so an account can see which identities
it asked for and what the operator decided.

What a recipient can do with the file is part of the claim. It is one JSON
object. Post and topic bodies are the markdown source as written, so they
re-publish anywhere that renders CommonMark without passing back through this
forge. Push receipts carry the WAL sequence and ref map a clone does not, so
they re-attach a history to who pushed it and when. Identifiers are this
forge's UUIDs, but every cross-reference inside the document — a post to its
topic, a tip to its post, an event to its thread — resolves inside the document
itself. What the file does not carry is listed in its own `not_included`
section rather than left to inference.

## Independent verification

The WAL is the durable record of accepted pushes.
`OpenAgents.Forge.Pushes` acknowledges a push only after the WAL takes it, and
each node's bare repository is a disposable projection of that record. So the
question "does what the forge serves match what was pushed" has an answer that
does not require the operator's word, and `OpenAgents.Forge.Verification`
computes it from the WAL and the repository alone. It reaches no database,
which `EXIT-002` asserts structurally rather than promising.

It reports five distinct disagreements: an entry the store cannot produce, an
entry whose bytes no longer hash to the key the index recorded, entries that
are not the contiguous run from zero, a ref the repository serves that the WAL
never recorded, and an object the WAL says a push introduced that the
repository cannot produce.

Each accepted entry also commits to the entry before it. `EXIT-005` chains
every WAL entry to its predecessor, so a rewritten entry invalidates the link
of every entry after it and a rewrite can no longer be confined to one place.
The verifier recomputes the chain, reports a broken or missing link, and
accepts an anchor — a sequence and link obtained anywhere other than this log —
against which it reports a disagreement.

That link now leaves the operator's storage twice. A pusher gets it in their
own `git push` output. Everyone else gets it from
`/.well-known/openagents-forge-anchor.json`, which
`OpenAgents.Forge.AnchorPublisher` rewrites on an interval with each public
repository's head, and which needs no credential to read. A stranger who keeps
one of those documents can later report the rewrite that defeats content
addressing on its own.

The limit is worth naming as plainly as the capability, and publication moves
it rather than removing it. **The operator serves the anchor**, so the document
proves nothing on its own; its value is that keeping a copy is cheap and a copy
is what contradicts a later rewrite. Nobody outside the operator witnesses it,
which is why `/status` reports `anchor_published` and `anchor_witnessed` as two
separate facts and stays degraded on the second. Content addressing and the
chain make tampering *evident*, not *impossible*.
`docs/decisions/0008-publish-the-forge-wal-anchor-at-a-well-known-path.md`
records why this surface and not a mirror commit, a public transparency log, a
relay set, or a chain anchor, with what each of those would require.
`docs/2026-08-23-forge-wal-anchoring.md` weighs the options with their true
costs and stages them. Both state what none of them can do: an anchor detects
rewriting, never withholding.

## Mirror recovery

GitHub is a mirror and never authority, and that direction is load-bearing.
`EXIT-003` holds it in place from the recovery side: the module that rebuilds a
repository calls nothing that can consult the mirror, so a lost forge cannot
quietly promote GitHub to source of truth.

What a mirror can reconstitute is every commit, tree, blob, tag, and advertised
ref, because `OpenAgents.Forge.Pushes.mirror_now/1` is a `git push --mirror`.
What it cannot reconstitute is the record of who pushed what and when: no
sequence, no principal, no push time, and therefore no push receipts. Recovery
from the WAL re-derives all of it; recovery from the mirror derives none of it,
and `EXIT-003` proves both halves.

Two operational facts belong here rather than in a footnote. First,
`:forge_mirror_urls` is empty in `config/config.exs` but `config/runtime.exs`
reads `OPENAGENTS_FORGE_MIRROR_URLS_JSON`, and production sets it for
`openagents.com`, so a mirror does run and GitHub holds what the forge last
pushed there — `REPOSITORY-002` states that trade, and a direct push to GitHub
is overwritten rather than merged. Second, `mirror_now/1` is a force push of
every ref, which is the destructive half of that: it overwrites whatever the
mirror held rather than reconciling with it. Both statements were false here
until #188 measured the deployment against them.

### The mirror is lossy about evidence and richer about pre-seed objects

"The mirror is strictly lossy" is true of one thing and false of another, and
collapsing the two is what #188 found. The relation has two halves and a
boundary between them, and the boundary is the seed commit `eda094c6`.

**Everything the WAL records — the whole log, from the seed forward.** The
mirror is strictly lossy and is never an input to recovery. It carries objects
and refs and no evidence, so a forge restored from it serves the same source
with no record of who produced it. That is `EXIT-003`, and it is the half that
is load-bearing: the recovery path must not be able to consult GitHub, or
GitHub becomes authority by accident.

**Everything before the seed — 307 commits.** The relation is inverted. This
repository's log was seeded from a `--depth=1` fetch (#179), so the WAL holds
one commit per ref and no ancestry, and no rebuild can produce what the log
never held. Those commits are objects with no evidence attached anywhere: no
WAL entry, no sequence, no principal, no receipt. The mirror is the only copy
of them, which is exactly the input this document said was never an input.

Measured on 2026-08-25, both sides cloned fresh:

| Source | `main` commits | `git fsck` | Root of `main` | Holds `c91327d6` |
| --- | --- | --- | --- | --- |
| The forge | 461 | clean | `eda094c6`, the seed | no |
| GitHub mirror | 767 | clean | `a352f78e` | yes |

The counts are taken at different tips, because the forge was ahead of the
mirror when they were read; the gap itself is stable. `git rev-list --count
eda094c6` on the mirror is 308 — the seed and its 307 ancestors — and the forge
holds the seed alone.

The forge's clone is not broken by this and `EXIT-004` is not violated by it.
The clone succeeds, passes `git fsck`, and writes a `shallow` file naming five
reconciled boundaries, which is `EXIT-004`'s stated outcome after #179: history
that says where it stops is servable, and history that dangles is not. That was the state until the objects were imported. **The forge is now
canonical for its whole history**: the pre-seed commits are in its own log, a
clone carries them, and no reader has to go to the mirror for them. The
paragraph above records what was measured before the import, because the
reasoning that follows it was decided against that state.

### The decision about the 307 commits

Decided 2026-08-25 (#188): **import the objects, and do not manufacture the
evidence.** Three shapes were weighed.

**Import the objects and a push record for them.** Rejected, because it invents
evidence. A WAL entry carries a sequence, a principal, and a time, and
`OpenAgents.Forge.Pushes.reconcile_receipts/1` derives a receipt from every
entry. Writing entries that claim 307 pushes nobody made would publish receipts
for pushes that did not happen, in a log whose entire value is that a receipt
derives from the WAL and never from a second authority. Synthesizing the record
to make the count come out right destroys the thing the count was measuring,
and it is the defect class this tracker keeps finding.

**Record that the forge is canonical only from the seed forward, and stop.**
That is true, it is what this document now says about the present, and it is
not enough as an end state. It leaves the forge's own authority holding less
than its mirror does, so "GitHub is a mirror and never authority" reads as a
statement about the whole repository while being true only about evidence and
false about half the objects. It also leaves the only copy of this
repository's first year on an account the operator does not control, which is
the dependency this document exists to remove.

**Import the objects and keep the push record starting at the seed.** Chosen.
The objects and the evidence are different claims, and only one of them is
missing. The log gains the bytes; it gains no assertion about who pushed them.

`OpenAgents.Forge.Backfill.import_history/3` is that operation and it is
already written and proven — `test/openagents/forge/backfill_test.exs`, six
tests, including one that rebuilds from sequence zero afterwards and gets the
whole history back. It appends the bundle as an ordinary `git_bundle` entry
carrying the ref map unchanged, an empty shallow set, and a principal that
records who authorized the import rather than who authored the commits. It
proves the bundle against a throwaway repository sharing the projection's
objects and refuses to touch the log unless every boundary's recorded parents
resolve and the union walks the way `git upload-pack` walks it, because an
append-only log cannot retract a bad entry.

This does not weaken `EXIT-003`. The bytes arrive by an operator's hand on one
occasion, not by a code path reaching for GitHub: no module on the recovery
path gains a mirror call, and the proof that fails on one is untouched. What
changes afterwards is that the mirror stops being the only copy of anything.

**Executed 2026-08-25.** `OpenAgents.Forge.Backfill.import_history/3` appended
the bundle to `openagents.com`'s log at **sequence 426**, under the principal
`operator:14167547`, and closed all five recorded boundaries:

| Boundary | Parent the import supplied |
| --- | --- |
| `eda094c6` (the seed) | `c91327d6` |
| `23f0d64c` | `0fcbbbb8` |
| `521c208d` | `fdd00d4c` |
| `70cadbb5` | `f8a7822a` |
| `1f32e14d` | `e0e61fb1` |

The bundle was built from a fresh mirror clone over those five parents, 7.3 MB,
and `git bundle verify` reported a complete history before it was copied to a
node. `open_boundaries/1` answered with the five commits before the import and
with `[]` after it.

Measured after the import, on a clone taken fresh through the published
transport:

| | Before | After |
| --- | --- | --- |
| `main` commits | 461 | 787 |
| `shallow` file | five boundaries | absent |
| `git cat-file -t c91327d6` | could not read | `commit` |
| `git fsck` | clean | clean |

The counts are at different tips; the gap is what closed.

`OpenAgents.Forge.Verification.verify/2` reports no findings on all three
nodes, each at head sequence 426 with an identical chain link. The projection
is node-local while the log is shared (#251), so a node applies a new entry on
its own schedule: two nodes had applied 426 immediately, and the third sat at
425 for several minutes with its boundaries still open. It converged when
`Sync.ensure_fresh/2` ran, which is what `OpenAgents.Forge.GitHTTP` calls
before serving any git request — so a clone routed to a lagging node converges
it before it is answered rather than being served a grafted history. The
fallback that made this an attended operation, a rebuild from sequence zero,
was not reached on any node.

The mirror is no longer the only copy of anything.

## Exit

`EXIT-004` is the narrow claim that actually holds: a clone taken through the
published Git transport carries every advertised ref, every object behind those
refs that the WAL holds, and re-serves the same history from somewhere else
with the forge deleted. The one withheld namespace is `refs/internal/`, where
stack boundary commits are retained without being advertised; the proof asserts
that this is the *only* withholding, so hiding a branch would turn it red.

Where a ref's history reaches back past what the WAL holds, the clone is
grafted rather than truncated: a `shallow` file names the boundary, and the
copy is complete with respect to what the forge has and honest about where that
stops. `EXIT-004`'s #179 amendment states that outcome. The pre-seed section
above says what is on the other side of the boundary and where it lives.

That is exit for source. It is not yet exit for everything, and the remaining
gaps are named rather than softened.

The account export can now be encrypted to a key the operator does not hold.
`GET /data/export/account?recipient=age1…` returns an
[age v1](https://age-encryption.org/v1) document, decrypted with `age` or any
other implementation of that specification, from a private key generated on
your own machine that never reaches this forge. What that protects is the
file — its copies, whatever the response passes through, any later reading of
it by anyone who obtains it, the operator included. What it does not protect is
the contents, because the forge builds the export by reading plaintext
PostgreSQL and held every record before the encryption ran.
`docs/2026-08-24-private-export-encryption.md` records that boundary, the
threat model on both sides of it, and the four options rejected. Both halves
are published together at `GET /api/status`, so a reader who sees that an
export can be encrypted also sees that the store behind it is not.

No commitment to the WAL is published outside operator storage, and no column
is encrypted at rest. Those are covered by the gaps below rather than by a
claim. Saying so is the point. Five green invariants that assert less than they
appear to would be worse than five plus a recorded gap.

## Invariants

| Invariant | What it binds |
| --- | --- |
| `EXIT-001` | The export ledger matches the surface, in both directions. |
| `EXIT-002` | Served state is checkable against the WAL with no database. |
| `EXIT-003` | Recovery comes from the WAL; the mirror is strictly lossy and is never an input. |
| `EXIT-004` | A clone is complete and self-hosting. |
| `EXIT-005` | Every WAL entry commits to the entry before it, so a rewrite is total. |
| `EXIT-006` | The status surface discloses every gap the ledger records. |
| `ADMIN-001` | The operator surface is an enumerated set of reads and writes, and the enumeration is checked against the router. |

Their proofs are `test/openagents/data_rights/export_inventory_test.exs`,
`test/openagents/data_rights/account_export_test.exs`,
`test/openagents/forge/independence_test.exs`,
`test/openagents/forge/independence_disclosure_test.exs`,
`test/openagents/forge/wal_test.exs`, and
`test/openagents_web/operator_surface_test.exs`. Every proof was
mutation-checked:
each property was broken deliberately, the proof was confirmed to fail, and the
break was reverted.

## Disclosure

The gaps below are not only recorded here. `OpenAgents.Forge.Independence`
publishes them in `OpenAgents.NetworkStatus`, so `/status` and
`GET /api/status` report the forge as independence-degraded while any of them
stands, under `EXIT-006`. The export counts are read from the ledger rather
than restated, and the verification section counts the anchors actually
published and reports `anchor_witnessed` separately, so the difference between
a tamper-evident log, a published anchor, and a witnessed one is published
rather than blurred.

A forge that records its limits in a document and reports itself healthy on its
status page has hidden them.

The disclosure also publishes its own distance from the revision its proofs ran
against. Every claim in it is derived from the running node, and the running
node's code can be older than this ledger: in August 2026 the forge served a
revision 57 commits behind `main`, where the account export, the WAL chain, and
the disclosure itself did not exist, while every proof of them stayed green
(#187). `independence.deployment.behind` is the number of commits on the head
this node serves that the running revision does not carry, so a reader who
checks `/status` sees the gap without performing a rehearsal to find it (#246).

Its bound is the same withholding the rest of this document names. The distance
is measured against the head this node serves, so a forge that will not serve
its own repository, a node whose bare projection is empty, and a release built
from a revision this forge never accepted all report `known: false` and no
distance at all. Being behind is reported beside the independence verdict, not
inside it: a node one commit behind is not less independent.

## Rehearsals

`docs/forge-exit-rehearsals.md` defines six rehearsals — restore, receipt
verification, mirror divergence, key rotation, operator loss, and partial
export — with what each proves, what it cannot, and whether anyone has run it.
Five of the six have never been run outside the test suite, and the one that
was run against the live forge failed: a full clone of this repository aborts
on a missing object 275 commits behind `main` (#179). `EXIT-004` was green
throughout, because it runs against a forge the test builds and never against
the one people clone from.

## Open gaps

| Gap | Issue |
| --- | --- |
| The live forge cannot serve a full clone of its own repository | #179 |
| The published WAL anchor is served by the operator and witnessed by nobody, so a consistent rewrite is caught only by a reader who kept a copy | #151 |
| No column is encrypted at rest, so the operator reads the source every export is built from | #193 |
| Five of six exit rehearsals have never been performed | #180 |
