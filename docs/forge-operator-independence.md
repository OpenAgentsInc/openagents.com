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
- **Write through several product surfaces.** Deployment starts, forum
  moderation, agent suspension, artifact listings, and continual-learning jobs
  are operator writes today. `ADMIN-001` still describes the operator path as
  read-only with one exception, which is now understated; issue #146 tracks
  correcting it.

### What the operator can see

- **Every account.** `OpenAgents.Admin` reads the account roster with display
  identity, status, join and last-authentication times, and message and issue
  counts.
- **Recorded call audio.** `OpenAgentsWeb.AdminRecordingController` unseals and
  streams any account's call recording. The privacy copy in the product says
  so.
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
recordings an operator opened.

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
- **Conversations, memory, and voice disclosure.** `GET /data/export`,
  `GET /data/export/atif`, and `GET /memory/export`, under `DATA-004`.

What is blocked today, and this is the honest headline: **if you keep your work
in a private repository, you cannot read your own comments, labels, milestones,
or assignees through any published route.** Six families resolve the repository
through a public-only query, so they answer `404` to their own owner and a
bearer token does not widen them. Issue #142 closes that.

What is reachable but has no account-scoped export: forum posts, deployments,
agent links, Box leases, paired computers, pull requests, stacks, and
reputation attestations. There is also no cross-repository read anywhere —
every issue and project route is scoped to one repository, and the only
account-wide list is `GET /api/v3/user/repos`. Push receipts have no published
route at all. Issue #143 covers the account-scoped export.

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

The limit is worth naming as plainly as the capability. WAL entries are not
signed and the index is anchored nowhere outside the operator's own storage, so
an operator who rewrites an entry, its key, and the index together produces a
self-consistent log. Content addressing makes tampering *evident*, not
*impossible*. It catches a partial rewrite, a lost object, and a ref moved out
of band; it does not catch a complete and consistent forgery. Closing that gap
needs a signature or an external anchor, and this forge has neither.

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

That is exit for source. It is not yet exit for everything: the metadata plane
— comments and labels in private repositories, forum posts, receipts — is
covered by the gaps above rather than by a claim. Saying so is the point. Four
green invariants that assert less than they appear to would be worse than three
plus a recorded gap.

## Invariants

| Invariant | What it binds |
| --- | --- |
| `EXIT-001` | The export ledger matches the surface, in both directions. |
| `EXIT-002` | Served state is checkable against the WAL with no database. |
| `EXIT-003` | Recovery comes from the WAL; the mirror is strictly lossy and is never an input. |
| `EXIT-004` | A clone is complete and self-hosting. |

Their proofs are `test/openagents/data_rights/export_inventory_test.exs` and
`test/openagents/forge/independence_test.exs`. Every proof was mutation-checked:
each property was broken deliberately, the proof was confirmed to fail, and the
break was reverted.

## Open gaps

| Gap | Issue |
| --- | --- |
| Private-repository metadata reads answer `404` to their owner | #142 |
| No account-scoped export of forge-owned and forum-owned data | #143 |
| `ADMIN-001` understates the operator surface | #146 |
| WAL entries are unsigned and anchored nowhere outside operator storage | #151 |
