# Forge exit rehearsals

**Date:** 2026-08-23
**Issue:** #94
**Companion:** `docs/forge-operator-independence.md` states the trust boundary
this document rehearses against.

A property nobody has exercised is a belief. `EXIT-001` through `EXIT-006`
check what can be checked in a test process against a forge the test builds,
and that is worth having, but it leaves two things unproven: whether the same
steps work on the live forge, and whether the steps a person would have to
perform by hand are written down well enough to follow.

This document defines six rehearsals. Each one says what it proves, what it
cannot prove, and whether it has been performed. **Performed** means someone
ran it and recorded the result here. Anything else says so.

## Rehearsal status

| Rehearsal | Executable proof | Performed against the live forge |
| --- | --- | --- |
| 1. Restore a repository and its work history | `EXIT-004`, `EXIT-001` | 2026-08-23 — **failed**, see #179 |
| 2. Detect a forged, missing, reordered, or mismatched receipt | `EXIT-002`, `EXIT-005` | No |
| 3. Mirror divergence | `EXIT-003` | No |
| 4. Key rotation | None | No |
| 5. Operator loss | `EXIT-003` | No |
| 6. Partial export | `EXIT-001` | No |

Five of the six have never been run outside the test suite, which #180 carries.
That is the honest state, and the one that was run failed.

## 1. Restore a repository and its bounded work history

**Proves:** an account's source and its work records survive on a machine that
has no access to this forge.

**Cannot prove:** that the operator did not withhold something before you
started. Nothing in this rehearsal detects withholding; see
`docs/2026-08-23-forge-wal-anchoring.md`, section 4.

### Steps

1. Take the source. On a machine that holds no forge credential beyond one
   `oa_pat_` token with `forge:write`:

   ```sh
   git clone https://openagents.com/{owner}/{repo}.git restored
   cd restored && git fsck --no-progress
   ```

2. Confirm the clone re-serves without the forge. Clone from your own copy and
   check the head matches:

   ```sh
   git clone --no-local restored second
   git -C second rev-parse HEAD
   ```

3. Take the work history. In a browser signed in as the account:

   - `GET /data/export/account` — forum topics and posts, threads and
     transcripts, push receipts, deployment requests and approvals, Box leases
     and runs, paired computers, agent links, pull requests, stacks, and issue
     dependencies.
   - `GET /data/export` and `GET /data/export/atif` — the conversation.
   - `GET /memory/export` — profile memory.

4. Read the export offline. Every record names its context in readable terms —
   a repository path, a topic and board slug, an issue number, an agent handle
   — so nothing in the document needs this forge to resolve. That property is
   proven in `test/openagents/data_rights/account_export_test.exs`.

5. Read `"not_included"` and `"bounds"` in the export before concluding you
   have everything. A truncated collection says so in its own `*_truncated`
   flag.

### Result, 2026-08-23

**Step 1 failed.** A full clone of `OpenAgentsInc/openagents.com` from the live
forge aborts: the served repository cannot produce commit `c91327d6`, an
ancestor of `main` 275 commits back. Clones at depth 200 succeed and pass
`git fsck`; depth 300 and deeper fail. Filed as #179 with the bisection.

This is exactly the failure `EXIT-004` describes and exactly why the invariant
alone was not enough: it runs against a forge the test builds, never against
the one people clone from. Steps 3 through 5 were exercised through the
executable proofs rather than by hand.

**Diagnosed, same day.** Nothing was lost. The forge never held `c91327d6`.
This repository's log was seeded from a `--depth=1` fetch, which copies one
commit per ref and no ancestry, and it was written before WAL entries carried
a `shallow` key. The log therefore records no boundary, replay had none to
write, and the projection reached disk holding a commit whose parent it did
not have. Asked for that parent, the forge answers `not our ref`: the object
is absent rather than corrupt, and no rebuild from the WAL can produce it,
because the WAL never held it either. Everything pushed since the seed —
282 commits — is present and intact.

`main` is not the only ref this reached, and one object found by hand was not
the only one. Probing every advertised ref by clone depth: five branches —
`codex/admin-posthog-analytics`, `codex/github-backed-repositories`,
`codex/posthog-integration`, `components-gallery`, and `repos-ui` — fail at
depth 2, so each holds its seeded tip and not that tip's parent. `main` and
the other seventeen serve to depth 25 and share `main`'s boundary. That is six
absent objects at six boundaries, one mechanism rather than six losses: the
`--depth=1` seed copied one commit per ref, and a ref keeps that boundary
until something pushes across it.

What broke the clone is the missing graft rather than the missing history. A
`shallow` file naming the seed commit stops the walk at the boundary, and a
clone then succeeds and reports honestly that history ends there; without it
`git upload-pack` walks past the boundary and aborts the whole transfer. Every
check the forge had asked whether ref *tips* resolved, and they all did, which
is why `EXIT-004` stayed green throughout.

`EXIT-004` now walks the exportable refs instead of listing them, and
`OpenAgents.Forge.Sync` reconciles the graft against the objects a projection
actually holds, so a repository that cannot be walked repairs itself from the
WAL. The pre-seed history remains outside this forge and is not recoverable
from it. Rerun step 1 to confirm the live forge serves a full clone.

## 2. Detect a forged, missing, reordered, or mismatched receipt

**Proves:** a verifier holding only the WAL and the bare repository — no
PostgreSQL, no operator credential — reports each way the served state can
disagree with the record.

**Cannot prove:** that a *consistent* rewrite happened. `EXIT-005` chains every
entry to its predecessor, so a rewrite cannot be confined to one entry, but an
operator who rewrites the whole suffix produces a self-consistent log. Only an
anchor held somewhere the operator does not control refutes that, and none is
published yet (#168). `GET /api/status` reports this as
`independence.verification.anchor_published: false`.

### Steps

1. On the forge host, with no database available:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Verification.verify("{storage_key}") |> IO.inspect()'
   ```

2. Expect `findings: []`. Each non-empty finding names one disagreement:
   `entry_object_missing`, `entry_digest_mismatch`, `entry_sequence_broken`,
   `served_refs_diverged`, `object_missing`, `chain_link_mismatch`, or
   `chain_link_missing`.

3. Anchor the check against a link you remember from an earlier run:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Verification.verify("{storage_key}", anchor: %{seq: 41, link: "…"}) |> IO.inspect()'
   ```

   A rewritten prefix reports `anchor_mismatch`. Without the anchor argument
   the same log reports clean, which is the whole point of publishing one.

## 3. Mirror divergence

**Proves:** the GitHub mirror is never an input to recovery, and divergence is
reported rather than reconciled silently.

**Cannot prove:** that the mirror is complete. It is strictly lossy by design:
`EXIT-003` records what it cannot give back.

### Steps

1. Compare heads:

   ```sh
   git ls-remote https://openagents.com/{owner}/{repo}.git refs/heads/main
   git ls-remote https://github.com/{owner}/{repo}.git refs/heads/main
   ```

2. A difference is expected whenever the forge is ahead. Automatic mirroring is
   not configured, so GitHub stays at whatever was last pushed to it.
   `OpenAgents.Forge.MirrorWatch` publishes freshness on `/status`.

3. Confirm the divergence changes nothing about authority. Rebuild from the WAL
   and check the head is unchanged:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Sync.rebuild("{storage_key}")'
   ```

   The rebuild path takes no mirror input. `EXIT-003` turns red if one is
   added.

## 4. Key rotation

**Proves:** nothing yet. This rehearsal is written and has never been
performed.

The forge holds several key-like secrets and they rotate differently:

- **The forge operator token.** One static token authorizes read and write on
  every configured repository with no membership check. Rotating it means
  replacing the environment value and restarting; every push made with it
  records the principal `operator:forge-token`, so no rotation makes past
  pushes attributable to a person.
- **Account `oa_pat_` tokens.** Created and revoked per account through
  `OpenAgents.ApiTokens`. Only the digest is stored, so a lost token is
  replaced rather than recovered.
- **The reputation issuer key.** `OpenAgents.Reputation.admit_key/1` admits a
  public key with a validity window. Rotation is issuing under a new key;
  attestations signed by the retired key stay verifiable against the admitted
  public key, which is why the key is admitted rather than assumed.
- **The three hand-rolled vaults.** Each takes its key from the operator's own
  environment, so rotation is an operator action with no separation of duties.
  `docs/forge-operator-independence.md` records that plainly.

**What a rehearsal must establish:** that a rotation of each of these leaves
every already-issued receipt verifiable, and that a rotation performed in the
wrong order is refused rather than silently invalidating history.

## 5. Operator loss

**Proves:** nothing yet outside `EXIT-003`, which shows recovery comes from the
WAL and never from the mirror.

**What a rehearsal must establish:** that a second operator, starting from the
WAL and the exported metadata alone, brings the forge back without treating
GitHub as canonical. `EXIT-004` covers the source half in a test process. The
metadata half depends on the exports in rehearsal 1, and the credential half
depends on rehearsal 4.

**What no rehearsal here can establish:** that a second operator can obtain the
WAL at all. It lives in storage the current operator controls, and this
repository contains nothing that changes that.

## 6. Partial export

**Proves:** an export that cannot return everything says so rather than
returning a shorter document that reads as complete.

### Steps

1. Read the export document's `"bounds"` and every `*_truncated` flag. Each
   collection publishes its own cap; a truncated collection is flagged, and Box
   run output reports the full byte size alongside the capped bytes.
2. Read `"not_included"`. It names the families the document does not carry and
   why, including the one repository-keyed family that has no account-scoped
   read (#171).
3. Compare against `OpenAgents.DataRights.ExportInventory`, which `EXIT-001`
   enforces against the surface in both directions, and against the same
   counts published at `GET /api/status` under `independence.export`.

## What these rehearsals do not cover

- **Withholding.** No rehearsal detects an operator who serves nothing or
  serves stale state.
- **Confidentiality.** No export is encrypted to a key the recipient holds, and
  no column in this repository is encrypted at rest (#178).
- **Attribution of operator reads.** No operator read is audited, so no
  rehearsal can show one did not happen.
