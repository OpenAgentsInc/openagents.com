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
outside `/api/v3`, into four statuses:

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
  collection states its cap and reports its own truncation.
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

What is reachable and still has no account-scoped read: reputation
attestations. This is the one repository-keyed family issue #165 could not
move, and the reason is not enumeration. An attestation names a `subject_id`
that the issuer supplies and an `issuer_key_id` that is the operator's; no
column, and no table on this surface, resolves either to an account, and no
route creates an attestation. There is no filter that would find an account's
own attestations, so the export names the gap in `not_included` rather than
returning an empty list that reads like an answer. Issue #171 carries the
subject binding that would make the read possible.

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

The limit is worth naming as plainly as the capability, and the chain moves it
rather than removing it. Nothing here publishes a link outside the operator's
own storage yet, so an operator who rewrites an entry, its key, the index, and
every link after it produces a self-consistent log that verifies clean.
Content addressing and the chain make tampering *evident*, not *impossible*.
What the chain buys is that one link remembered elsewhere now covers a whole
prefix of the log, which is why the next step is publication and not
cryptography. `docs/2026-08-23-forge-wal-anchoring.md` weighs the options —
a client-side receipt to the pusher, a periodic external anchor, and signing —
with their true costs, and stages them. It also states what none of them can
do: an anchor detects rewriting, never withholding.

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
`:forge_mirror_urls` is empty in `config/config.exs` and set by no environment,
so no mirror runs today and GitHub holds whatever was last pushed to it
directly — `REPOSITORY-002` states that trade. Second, `mirror_now/1` is a
force push of every ref, so configuring a mirror overwrites whatever direct
pushes left there rather than merging with them.

## Exit

`EXIT-004` is the narrow claim that actually holds: a clone taken through the
published Git transport carries every advertised ref, every object behind those
refs, and re-serves the same history from somewhere else with the forge deleted.
The one omission is the `refs/internal/` namespace, where stack boundary
commits are retained without being advertised; the proof asserts that this is
the *only* omission, so withholding a branch would turn it red.

That is exit for source. It is not yet exit for everything: an account cannot
identify its own reputation attestations, private repository exports are not
encrypted, and no commitment to the WAL is published outside operator storage.
Those are covered by the gaps above rather than by a claim. Saying so is the
point. Five green invariants that assert less than they appear to would be
worse than five plus a recorded gap.

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
than restated, and the verification section reports `anchor_published` as
`false` while no anchor is configured, so the difference between a
tamper-evident log and a tamper-proof one is published rather than blurred.

A forge that records its limits in a document and reports itself healthy on its
status page has hidden them.

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
| No binding from a reputation attestation's subject to an account, so an account cannot identify its own attestations | #171 |
| No commitment to the WAL is published outside operator storage, so a consistent rewrite still verifies clean | #151 |
| No export is encrypted to a key the recipient holds, and no column is encrypted at rest | #178 |
| Five of six exit rehearsals have never been performed | #180 |
