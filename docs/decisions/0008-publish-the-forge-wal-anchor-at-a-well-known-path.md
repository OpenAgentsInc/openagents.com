# ADR 0008: Publish the forge WAL anchor at a well-known path

Date: 2026-08-23

Status: Accepted

Issue: #170. Parent: #151. Implemented by #168.

## Context

`EXIT-002` checks what the forge serves against the WAL that accepted it, and
its own conclusion is that the check compares two things the operator holds.
`EXIT-005` chains every WAL entry to its predecessor, so a rewrite of an
accepted push can no longer be confined to one entry: changing entry *k*
changes the link of every entry after it. One link remembered outside the
operator's storage therefore checks the entire prefix of the log before it.

`git push` now prints that link, so a pusher can keep it. That serves exactly
one verifier — the person who pushed, for the one repository they pushed to,
up to the one sequence they wrote down. It is not publication. A reader of a
public repository, an auditor, or anyone arriving later has no commitment at
all, and an operator who rewrites the WAL, the content-addressed entry keys,
the index, every chain link, and the derived `forge_pushes` rows produces a
self-consistent forge that `verify/2` reports clean.

`docs/2026-08-23-forge-wal-anchoring.md` section 3.3 lists the publication
surfaces and calls the choice between them a cost and custody decision rather
than an implementation one. This ADR is that decision.

### Who the verifier is

The options only rank once this is settled, and it is settled by looking at
who reads the forge. Three classes:

1. **The pusher.** Already served, by the receipt `EXIT-005` prints. Needs
   nothing further.
2. **A stranger reading a public repository.** Served by nothing today. They
   read `/changelog`, `/<owner>/<repo>`, and a clone, and they have no way to
   tell whether the history they are reading is the history that was accepted.
3. **Someone reconstructing the past after an incident.** Served by nothing
   today, and worst placed of the three: they arrive after the fact and cannot
   retroactively obtain a commitment.

Classes 2 and 3 are the ones this decision is for. Both need a commitment they
can reach **without an account, without a credential, and without asking the
operator for anything**, and class 3 needs it to have been reachable *before*
the rewrite it is trying to detect.

## Decision

**Publish one JSON anchor document at a stable well-known path, on an
interval, from a job off the push path. Do not sign it. Chain each anchor to
the digest of the anchor before it. State on the document itself, and on
`/status`, that the document is published by the operator and witnessed by
nobody.**

The document carries, per repository the forge already publishes to anonymous
readers: the entry count, the head sequence, the head chain link, a digest of
the exportable ref map, and the first sequence the chain covers. It carries the
anchor's own sequence, its `published_at`, and the digest of the previously
published anchor document.

### What this proves

**On its own, nothing.** The operator serves the document and can serve any
document. This is the whole reason the decision is written down rather than
implied by the code: a publication surface that reads as proof while depending
on the operator is a worse failure than the gap it papers over.

What it does is make a commitment **cheap to keep a copy of**, and a copy is
the thing that contradicts a rewrite. Specifically:

- **It extends the pusher's receipt to everyone.** Any reader can now hold a
  commitment covering every public repository's whole log prefix, not only the
  pushes they made themselves.
- **One archived copy pins every anchor before it.** Each anchor names the
  digest of the previous anchor document, so the published sequence is itself a
  hash chain — the same trick `EXIT-005` plays on WAL entries, applied one level
  up. A reader who kept anchor 400 has a commitment to anchors 1 through 399,
  and through them to the WAL prefixes those anchored.
- **It makes stopping visible.** `published_at` advances every interval whether
  or not the log moved, so a reader can tell publication has halted. #168 is
  explicit that a halt is indistinguishable from an outage until somebody
  notices; this is what gives them something to notice.
- **It is the artifact every stronger option needs anyway.** A mirror commit,
  a transparency-log entry, and a timestamp proof all publish *this document's
  digest*. Escalating is additive rather than a rewrite of the surface.

A third-party web archiver that snapshots the URL holds a copy the operator
cannot edit. Whether anyone does that is not a claim this repository can make,
and nothing here asserts it.

### What it does not prove

- **Nothing is witnessed.** No party other than the operator attests that this
  document existed at this time with these contents. The status disclosure
  therefore publishes `anchor_published: true` and `anchor_witnessed: false`
  as two separate facts, and `degraded` stays true on the witness axis.
- **A reader who kept no copy holds nothing**, exactly as a pusher who kept no
  receipt holds nothing. The surface makes keeping a copy possible and cheap; it
  cannot make anyone do it.
- **Everything after the last anchor is unanchored.** The exposure window is
  the publication interval.
- **A split view is not closed.** One document served to one reader and another
  to another is caught only when readers compare. A single public surface with
  plural readers narrows it and does not shut it.
- **Withholding is untouched**, as it is by every option here. An operator who
  deletes a repository, serves stale state, or refuses a clone still holds all
  of those powers. Anchoring tells you the history you *can* read is the history
  that was accepted.
- **Completeness is untouched.** An anchor over a truncated log is a valid
  anchor over a truncated log.

### Why the head is not signed

`docs/2026-08-23-forge-wal-anchoring.md` section 3.2 settles this and the
decision keeps it. A signature over an operator-served document, made with a key
the operator holds, adds nothing against the operator — which is the threat this
whole lane exists for. The network attacker it would defend against is already
covered by TLS. Adding a signature would make the surface look like proof while
changing nothing about who has to be trusted, so the anchor is unsigned and says
why on its face.

Signing becomes worth building when the key lives somewhere the operator
genuinely cannot reach. That is an organizational change, not a code change.

## Options rejected, and what each would require

### A commit to the GitHub mirror

**Would prove:** GitHub records force pushes in its own event history and does
not answer to this operator, so a mirrored anchor commit is witnessed by a party
with no interest in this forge. A stranger can read it without an account.

**Rejected because the component does not exist.** `:forge_mirror_urls` is empty
in `config/config.exs` and set by no environment, so no mirror runs today, and
`OpenAgents.Forge.Pushes.mirror_now/1` is `git push --mirror` — a force push of
every ref. Shipping an anchor whose security story rests on a mirror nobody has
provisioned would be an assertion nothing can contradict.

It is also weaker than it first reads. A branch reached by `--mirror` is
force-writable by the same credential, so the anchor *branch* is not
append-only. What GitHub keeps that the operator cannot rewrite is the **push
event log**, a different artifact that nothing in this repository reads and that
GitHub exposes on its own terms.

**To adopt:** provision a mirror repository and a scoped credential, decide
whether the anchor goes on a ref the mirror force push can reach, and name what
reads GitHub's event history. Then publish this document's digest there.

### A public append-only transparency log

**Would prove:** the strongest routinely available property. A log with
independent monitors and witnesses gives inclusion proofs a stranger can check
and real split-view resistance, which is the one limit publication alone cannot
close.

**Rejected because it needs a relationship and a client that do not exist.**
There is no account with any log operator, no key registered with one, and no
Elixir client for Sigsum, Rekor, or a Certificate-Transparency-shaped log in
this repository. Verification would also depend on that log's own tooling, which
a reader would have to obtain separately.

**To adopt:** someone owns the account and the submission key, a client lands
with its failure modes bounded off the push path, and the reader-facing
verification path is documented end to end. This is the correct escalation and
the one that closes split views.

### A Nostr relay set

**Would prove:** replication to hosts the operator does not run. An event
published to a diverse relay set is hard to retract everywhere at once, and the
diversity is the property, not the signature.

**Rejected because it costs a protocol client, a key, and a retention
assumption.** This repository has no Nostr client; the workspace's
`nostr-effect` is another repository's TypeScript library and not a dependency
here. Relay retention is each relay's policy, so "published" and "still
retrievable next year" are different claims. The signing key is the operator's,
which the unsigned-head reasoning above already weighs.

**To adopt:** a client lands, a relay set is chosen with its diversity argued
rather than assumed, and someone states what retention is being relied on.

### A Bitcoin-anchored commitment

**Would prove:** the strongest ordering and time property available, and the
only one where no party at all has to be trusted. An OpenTimestamps proof
verifies against the chain itself, so even the calendar servers are not trusted.

**Rejected because the client does not exist and the variant that avoids it
costs custody.** There is no OpenTimestamps implementation in this repository
and no `ots` binary in the deployment; the OP_RETURN variant needs a funded
wallet and a spending key, which is money custody added to a transparency
problem. Verification also needs a Bitcoin node or a block explorer, and the
proof only upgrades hours after the anchor.

Worth stating even so: Bitcoin anchoring proves existence and time, never
completeness. An anchor over a truncated log is still a valid anchor.

**To adopt:** an OpenTimestamps client lands, stamping runs off the publication
path with its latency tolerated, and the reader-facing verification path is
documented. This is the right option if the forge ever needs its history to
survive an adversarial operator over years.

## Consequences

- `/status` and `GET /api/status` publish `anchor_published` and
  `anchor_witnessed` as two facts, not one, and the forge stays
  independence-degraded on the witness axis. `EXIT-006` derives both rather than
  restating them, so neither can drift.
- `EXIT-005` extends to cover publication. The invariant claims that the anchor
  is published and archivable, and states that it is not witnessed.
- #151's gap narrows rather than closing. Before this, a consistent rewrite was
  undetectable to anyone who kept nothing. After it, a consistent rewrite is
  undetectable to anyone who kept nothing *and* has to survive contact with
  every reader who kept an anchor. The operator still controls whether anyone
  ever gets a copy, so #151 stays open on the witness axis.
- The publication interval is the exposure window and is operator-owned
  configuration, which means the operator can lengthen it. That is disclosed by
  `published_at` rather than prevented.
- Escalation to any rejected option is additive: each one publishes this
  document's digest, so none of them requires changing the surface readers
  already fetch.
