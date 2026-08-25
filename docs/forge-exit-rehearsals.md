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

`test/openagents/forge/exit_rehearsal_runbook_test.exs` checks every
`OpenAgents` module and function this document names against the compiled
code. Rehearsal 3's step 3 once named `OpenAgents.Forge.Sync.rebuild/1`
before that function existed (#189), and no invariant could notice, because
invariants read compiled modules and the step was a string in this file. A
renamed or removed function now turns a test red instead of leaving a step
that reads as executable.

## Rehearsal status

| Rehearsal | Executable proof | Performed against the live forge |
| --- | --- | --- |
| 1. Restore a repository and its work history | `EXIT-004`, `EXIT-001` | 2026-08-23 — **failed**, see #179; steps 1 and 2 re-run 2026-08-25 and passed |
| 2. Detect a forged, missing, reordered, or mismatched receipt | `EXIT-002`, `EXIT-005` | 2026-08-25 — steps 1 and 3 pass; step 2 is local only; **new defect #251**, and #190 still reproduces |
| 3. Mirror divergence | `EXIT-003` | 2026-08-25 — steps 1 and 2 pass and confirm #188; step 3 is local only |
| 4. Key rotation | `test/openagents/forge/key_rotation_test.exs` | 2026-08-25 — passes in the test process; **new defect #253** |
| 5. Operator loss | `EXIT-003` | 2026-08-25 — recovery passes in the test process; the WAL remains unobtainable, now measured |
| 6. Partial export | `EXIT-001` | 2026-08-25 — passes against the live forge; **new defect #252**, found red on `main` and since classified |

Every row now names a date and a result.
`docs/2026-08-25-forge-exit-rehearsals-2-to-6.md` records what running
rehearsals 2 through 6 produced, and which half of each ran against the live
forge rather than against a forge a test process builds. Three steps mutate
state — rehearsal 2's tampering, rehearsal 3's rebuild, and any rotation in
rehearsal 4 — so they were performed locally and are labeled local there. A
rehearsal that cannot safely run its destructive step against production has a
permanent gap, and that record says so rather than implying the step was taken.

## Release re-check, 2026-08-25

#187 found one cause behind six live failures on 2026-08-23: `main` held the
exit surfaces and the deployed revision did not, so every invariant stayed
green while the forge served none of them. A release carrying them was
promoted, and each row was measured again against the live forge on revision
`46cf8a5aea3791936c22e82c145a9a8dd734374d`.

| Surface | Invariant | 2026-08-23 | 2026-08-25 |
| --- | --- | --- | --- |
| `GET /data/export/account` | `EXIT-001` | `404` | `302` to sign-in, so the route exists |
| `GET /api/v3/repos/{owner}/{repo}/pushes` | `EXIT-005` | `404` | `200`, and `200` at the `/api/v1` path the route moved to |
| `independence` section of `GET /api/status` | `EXIT-006` | absent | present, `degraded: true`, all four subsections served |
| `OpenAgents.Forge.WAL.chain_link/2`, `OpenAgents.Forge.WAL.entry_link/1` | `EXIT-005` | not exported | both exported on the node |
| `OpenAgents.Forge.Verification.verify/2` `:anchor` option | `EXIT-005` | `verify/1` only | `verify/2` exported, and a wrong anchor reports `anchor_mismatch` |
| The `shallow` graft reconciliation | `EXIT-004` | absent, clone aborted | present, and a full anonymous clone completes |

The chain claim is the one that changed shape rather than flipping. On
2026-08-23 the log carried 0 links across 275 entries. It now carries 97
across 376: the contiguous suffix 279 through 375, with `chained_from: 279`.
That is what `EXIT-005` describes rather than a partial fix — a chain that
starts in the middle is history, and no entry written since the chain shipped
is missing a link. Rehearsals 1 and 2 above record the measurements.

**What the re-check does not close.** Nothing reported this gap; a person
found it by rehearsing six surfaces by hand, and the release that closed #187
removes today's gap rather than the next one. #246 carries that, and the
obvious home for it is not free: `EXIT-006`'s proof turns red when a commit
sha reaches the disclosure.

**What #246 added.** The disclosure now publishes its own distance from the
revision its proofs ran against. `independence.deployment.behind` on `/status`
and `GET /api/status` is the number of commits on the head this node serves
that the running revision does not carry, so the next 57-commit gap is a
number on a public page rather than a rehearsal waiting to be performed. The
proof stayed as it was: a distance is a count, and neither revision it lies
between reaches the projection. What it still does not report is a forge that
withholds its own repository — that node reports `known: false` and no
distance, the same withholding `EXIT-005` and `EXIT-006` already decline to
detect — and it does not act on the gap it reports. Nothing raises an incident
when the distance grows; a reader or a check has to look.

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

### Result, 2026-08-25

**Steps 1 and 2 pass.** Live revision
`46cf8a5aea3791936c22e82c145a9a8dd734374d`, which carries the reconciliation.
An anonymous clone of `OpenAgentsInc/openagents.com` over the published
transport completes, checks out `adafa83`, carries 417 commits, and passes
`git fsck --no-progress` with no output. The clone is grafted rather than
truncated: it writes a `shallow` file, which is `EXIT-004`'s stated outcome,
because history that says where it stops is servable and history that dangles
is not. Cloning that copy with `--no-local` produces the same head and passes
`git fsck` with no forge in the path, which is step 2.

The repair is visible on the node rather than inferred from the clone. The
bare projection holds five reconciled boundaries in its `shallow` file, its
`OpenAgents.Forge.Repos.graft_seq_at/1` marker equals its applied sequence,
and the walk
`upload-pack` performs — `git rev-list --objects --quiet --all` — exits `0`.

Steps 3 through 5 were not performed. `GET /data/export/account` answers `302`
to an unauthenticated request, which is the route reached rather than the
export read, and the document itself stays covered by
`test/openagents/data_rights/account_export_test.exs`. Rehearsal 1 is
therefore performed for the source half and not for the work-history half.

## 2. Detect a forged, missing, reordered, or mismatched receipt

**Proves:** a verifier holding only the WAL and the bare repository — no
PostgreSQL, no operator credential — reports each way the served state can
disagree with the record.

**Cannot prove:** that a *consistent* rewrite happened. `EXIT-005` chains every
entry to its predecessor, so a rewrite cannot be confined to one entry, but an
operator who rewrites the whole suffix produces a self-consistent log. Only a
commitment held somewhere the operator does not control refutes that. One is
published now, at `/.well-known/openagents-forge-anchor.json` (#168), and
`GET /api/status` reports
`independence.verification.anchor_published: true`. Publishing a commitment is
not having one witnessed: the operator serves that document and could serve
any document, so it refutes a rewrite only for a reader who kept a copy.
`anchor_witnessed` stays `false`, and #151 carries the witness.

### Steps

1. On the forge host:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Verification.verify("OpenAgentsInc/openagents.com") |> IO.inspect()'
   ```

   The argument is the repository you clone — an `owner/name` path, or the
   name `OpenAgents.Forge.Repos.allowed_repos/0` lists.
   `OpenAgents.Forge.RepoRef` resolves it to the storage key the log is kept
   under, and the report names both, so you can see which repository was
   checked. A storage key still works and is the reference to use with no
   database available: resolving a *name* is the one step that reads the
   `repositories` table, and a key resolves against the WAL alone. A name that
   names no repository here, or two, is reported as `repository_not_found` or
   `repository_name_ambiguous` rather than checked as if it were a key
   (issue #190).

2. Expect `findings: []`. Each non-empty finding names one disagreement:
   `entry_object_missing`, `entry_digest_mismatch`, `entry_sequence_broken`,
   `served_refs_diverged`, `object_missing`, `chain_link_mismatch`, or
   `chain_link_missing`.

3. Anchor the check against a link you remember from an earlier run:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Verification.verify("OpenAgentsInc/openagents.com", anchor: %{seq: 41, link: "…"}) |> IO.inspect()'
   ```

   A rewritten prefix reports `anchor_mismatch`. Without the anchor argument
   the same log reports clean, which is the whole point of publishing one.

### Result, 2026-08-25

**Steps 1 and 3 pass** against this repository's log, storage key
`ecd89cf6-f602-479f-9f47-266307345aaa`, on live revision
`46cf8a5aea3791936c22e82c145a9a8dd734374d`.

Step 1 reports `findings: []` over 376 entries, with
`head: %{seq: 375, link: "19c7a2c5…"}` and `chained_from: 279`. Ninety-seven
entries carry a link, which is the contiguous suffix 279 through 375. The
entries before 279 predate the chain and carry none, which `EXIT-005` states
is history rather than tampering: a chain that stops in the middle is a
finding, and a chain that starts in the middle is not. No entry written since
the chain shipped is unlinked.

Step 3 was performed three ways against the same log. The head link the log
itself reports verifies clean. A `link` of 64 zeroes at the head sequence
reports one finding, `anchor_mismatch`, naming the anchored and recorded
values. A sequence past the end of the log reports `anchor_unreachable`. The
option is therefore honored rather than accepted and ignored, which is what a
pusher holding a `remote: openagents wal-receipt` line depends on.

Two of the surfaces the step needs were confirmed on the node rather than
assumed: `OpenAgents.Forge.WAL` exports `chain_link/2` and `entry_link/1`, and
`OpenAgents.Forge.Verification` exports `verify/2` beside `verify/1`.
`GET /api/v1/repos/OpenAgentsInc/openagents.com/pushes` answers `200` and
serves the same head link and `chained_from` the verifier reports.

**Amended 2026-08-25 (issue #190).** Step 1 above used to say `{storage_key}`,
and the obvious value to substitute — the name
`OpenAgents.Forge.Repos.allowed_repos/0` returns, `openagents.com` — was not
one. It went into a path, the path held a bare repository that projects no log,
and the report was `wal_unreadable`: the finding that means "your write-ahead
log is missing", for a repository whose log is intact under the key
`ecd89cf6-f602-479f-9f47-266307345aaa`. `OpenAgents.Forge.RepoRef` now resolves
a name to a key before anything is read, so the step works with the name an
operator has, and a name that settles on no repository is
`repository_not_found` rather than an empty repository that looks half-alive.
The stale `openagents.com.git` bare repository on the live node is untouched by
that change: it is operator state, and removing it is an operator's decision.

The bound in this rehearsal's own preamble still holds, with one correction:
an anchor **is** published now, at
`/.well-known/openagents-forge-anchor.json`, and `GET /api/status` reports
`independence.verification.anchor_published: true` with `anchor_witnessed:
false`. A consistent rewrite is refuted only for a reader who kept a copy of
that document or a receipt line; nobody is attesting to it on the operator's
behalf, and #151 carries the witness.

**Step 2 has been performed only locally, and step 1 found a defect.** The
later pass recorded in `docs/2026-08-25-forge-exit-rehearsals-2-to-6.md`
verified the same log against the anchor the forge had already published, ran
step 2's tampering against a forge the test process builds rather than against
production, and ran step 1 on all three fleet nodes at once. The nodes gave
three different answers: the WAL is shared and the projection is node-local, so
a node that has not replayed an entry yet reports `served_refs_diverged` and
`object_missing`, which are the findings that mean tampering. #251 carries it,
and it blocks #179's scheduled verification pass. #190 also still reproduces:
`OpenAgents.Forge.Repos.allowed_repos/0` returns a name `verify/2` cannot use.

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

2. A difference is expected whenever the forge is ahead. A mirror **is**
   configured for `openagents.com` — `OPENAGENTS_FORGE_MIRROR_URLS_JSON` sets
   it, and #188 corrected the contracts that said otherwise — so read
   `forge.mirror` on `/status`, which `OpenAgents.Forge.MirrorWatch`
   publishes, rather than assuming GitHub is frozen.

3. Confirm the divergence changes nothing about authority. Rebuild from the WAL
   and check the head is unchanged:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Sync.rebuild("{storage_key}")'
   ```

   `rebuild/1` discards the local bare-repository projection and
   re-materializes it from the WAL, from sequence zero, with no mirror input.
   That is the recovery a wrong or damaged projection needs, unlike
   `ensure_fresh/1` and `replay_missing/3`, which trust the projection's
   applied-sequence marker and only replay what it has not yet applied. It
   returns `:ok` on success and a typed error when the WAL cannot produce a
   servable projection. `EXIT-003` turns red if a mirror input is added.

4. Measure history rather than ref maps. Identical ref maps are not identical
   history, and this is the step that finds a seeded repository whose log holds
   less than its mirror does:

   ```sh
   git clone https://openagents.com/{owner}/{repo}.git forge && \
     git -C forge rev-list --count refs/heads/main && \
     cat forge/.git/shallow
   git clone https://github.com/{owner}/{repo}.git mirror && \
     git -C mirror rev-list --count refs/heads/main
   ```

   A `shallow` file on the forge side names the boundaries. Each boundary's
   parents are what the log does not hold, and the mirror is where they are.

5. Where the forge is behind, close it with the objects and not with invented
   evidence. `OpenAgents.Forge.Backfill.import_history/3` appends a bundle to
   the log as a `git_bundle` entry that leaves the ref map alone and claims no
   push. Build the bundle from the mirror, one branch per boundary parent:

   ```sh
   git -C mirror branch --force preseed-1 <parent-of-boundary-1>
   # ... one per boundary ...
   git -C mirror bundle create pre-seed.bundle preseed-1 preseed-2 ...
   git -C mirror bundle verify ../pre-seed.bundle
   ```

   Put the bundle on the node, inside the container, and import it:

   ```sh
   bin/openagents rpc 'OpenAgents.Forge.Backfill.open_boundaries("{storage_key}")'
   bin/openagents rpc 'OpenAgents.Forge.Backfill.import_history("{storage_key}", "/tmp/pre-seed.bundle", "operator:{who}")'
   ```

   `import_history/3` proves the bundle against a throwaway repository that
   borrows the projection's objects and refuses to write unless every
   boundary's recorded parents resolve and the union walks, because an
   append-only log cannot retract a bad entry. `{storage_key}` is the
   repository's storage key, not its name — `OpenAgents.Forge.RepoRef` is the
   only translator, and #190 is the defect that made the difference matter.

   This is a permanent write on a forge people are pushing to. Watch every node
   converge afterwards: a node that cannot materialize the entry falls back to
   a full rebuild from sequence zero, which step 3 records as unexercised
   against the live projection.

### Result, 2026-08-25

**Steps 1 and 2 pass against the live forge.** Both remotes advertise the same
twenty-five refs, byte for byte, with `refs/heads/main` at
`e57f5ea8b1666ccb69fc4c626f54cf41b34a0ebe` on each, and the node reports
`openagents.com` as the one configured mirror.

Identical ref maps are not identical history, and the gap is #188's. A full
clone of each side: the forge serves 423 commits on `main`, `git fsck` clean,
grafted at five `shallow` boundaries with `eda094c6` as its root; GitHub serves
730, `git fsck` clean, rooted at `a352f78e`. The 307-commit difference is on
the mirror and in no WAL. For everything pushed since the seed the forge is
canonical and the mirror is lossy; for everything before it the relation is
inverted, which is what #188 asks the contracts to say.

**Step 3 was not run against production.** `rebuild/1` discards a projection,
and a rehearsal must be read-only against the forge people push to. Its
behavior was exercised locally instead, by three tests in
`test/openagents/forge/independence_test.exs`. Whether it succeeds against the
live 423-commit projection is untested.
`docs/2026-08-25-forge-exit-rehearsals-2-to-6.md` records both halves.

**Step 4 re-measured later the same day, and step 5 is prepared but not run.**
A fresh clone of each side: the forge serves 461 commits on `main`, `git fsck`
clean, grafted at five `shallow` boundaries rooted at `eda094c6`; the mirror
serves 767, `git fsck` clean, rooted at `a352f78e`, and `git rev-list --count
eda094c6` there is 308 — the seed and its 307 ancestors. The counts are at
different tips because the forge was ahead; the gap is unchanged.

The mirror holds all five boundaries and each one's parent, so a single bundle
closes every boundary at once. Built from the mirror by the recipe in step 5
over `fdd00d4c`, `e0e61fb1`, `0fcbbbb8`, `f8a7822a`, and `c91327d6`, it is
7.2 MB and `git bundle verify` reports a complete history.

The import itself was not performed. It is a permanent append to a shared
production log, its failure mode is the fleet-wide rebuild step 3 has never
exercised live, and both belong to an attended operation rather than to a
read-only rehearsal. #188 records the decision — import the objects, keep the
push record starting at the seed — and
`docs/forge-operator-independence.md` carries the reasoning.

## 4. Key rotation

**Proves:** that no rotation invalidates an already-issued receipt, and that a
rotation performed in the wrong order is refused rather than silently
invalidating history. `test/openagents/forge/key_rotation_test.exs` is the
proof, and the rehearsal was performed on 2026-08-25.

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
  public key, which is why the key is admitted rather than assumed. The
  ordering rule is enforced rather than assumed: `retire_key/2` refuses a
  `retired_at` at or before the newest attestation the key signed — the
  refusal names the conflicting attestation time — refuses one earlier than
  the key's `activated_at` when it signed nothing, and refuses one beyond a
  small clock-skew allowance in the future. There is deliberately no
  override: a backdated retirement is exactly the single-`UPDATE` move that
  silently unverifies published signatures (#191), and an issuer who must
  disown a claim publishes a linked revocation instead of rewriting the
  key's validity window.
- **The three hand-rolled vaults.** Each takes its key from the operator's own
  environment, so rotation is an operator action with no separation of duties.
  `docs/forge-operator-independence.md` records that plainly. Each vault seals
  under its own key (`INVARIANTS.md`, VAULT-001), and their rotation outcomes
  differ:
  - `OpenAgents.Accounts.TokenVault` (GitHub tokens) rotates without loss:
    the envelope names its key, the retired key joins
    `GITHUB_TOKEN_DECRYPTION_KEYS_JSON`, and
    `OpenAgents.Accounts.rotate_github_tokens!/0` rewraps every row under the
    active key.
  - `OpenAgents.Machines.TokenVault` (pairing tokens,
    `MACHINE_TOKEN_ENCRYPTION_KEY`) rotates with bounded loss: at most one
    ten-minute window of unclaimed pairings becomes unreadable, and a person
    retries the pairing. There is no keyring because no record outlives the
    window. The code no longer reaches the GitHub key, which is #192's fix,
    and since 2026-08-25 production provisions `MACHINE_TOKEN_ENCRYPTION_KEY`
    with its own value on every fleet node, so a GitHub key rotation no longer
    moves this vault's key. The boot bridge in `config/runtime.exs` survives as
    a fallback for a node that comes up without the secret, and
    `OpenAgents.RuntimeConfig.validate/1` refuses a staging or production boot
    whose pairing key equals the GitHub key, so the bridge can no longer be
    load-bearing without something failing. #253 closed on that.
  - `OpenAgents.Voice.RecordingVault` (call audio,
    `VOICE_RECORDING_ENCRYPTION_KEY`) rotates with permanent loss: one key,
    no key id, no keyring, so recordings sealed under the retired key never
    open again. Rotate it only when stranding prior recordings is the intent
    or an acceptable cost of suspected exposure.

**What a rehearsal must establish:** that a rotation of each of these leaves
every already-issued receipt verifiable, and that a rotation performed in the
wrong order is refused rather than silently invalidating history.

### Result, 2026-08-25

**Both halves pass in the test process.** A forge receipt depends on no key —
the WAL chain link is unkeyed and reproducible from the entry alone, and the
verifier is compiled against no secret and no vault — so no rotation can
invalidate one. The reputation issuer key's ordering rule refuses a backward
retirement and names the attestation it would have unverified, refuses one
earlier than a silent key's activation, and refuses one beyond the clock-skew
allowance. Each vault's rotation outcome is proven separately. Twelve tests,
all green.

**No key was rotated against production.** The live half is an inventory read
without printing key material, and it found one gap: `VOICE_RECORDING_ENCRYPTION_KEY`
is set and distinct, but `MACHINE_TOKEN_ENCRYPTION_KEY` is unset, so the
pairing vault runs on the GitHub vault's key (#253). It also found that the
GitHub retired keyring is empty and no reputation issuer key is admitted, so
neither rotation has ever run here.
`docs/2026-08-25-forge-exit-rehearsals-2-to-6.md` records the inventory.

**The gap is closed, 2026-08-25.** A later read the same day, again without
printing key material, answers `machine_set=true` and `same_as_github=false` on
all three fleet nodes, and all four vault keys are set and pairwise distinct.
`MACHINE_TOKEN_ENCRYPTION_KEY` is provisioned in Secret Manager and exported by
`ops/deploy/fleet-startup.template.sh`, and the fleet has rolled onto a revision
that carries it. `OpenAgents.RuntimeConfig.validate/1` now refuses a staging or
production boot on a borrowed vault key, so the next reader does not have to
compare two configured values by hand to learn whether the bridge is
load-bearing. The retired GitHub keyring is still empty and no reputation
issuer key is admitted; neither rotation has run.

## 5. Operator loss

**Proves:** that the source and the receipts come back from the WAL alone.
`test/openagents/forge/independence_test.exs` proves it in a test process, and
the rehearsal was performed on 2026-08-25.

**What a rehearsal must establish:** that a second operator, starting from the
WAL and the exported metadata alone, brings the forge back without treating
GitHub as canonical. `EXIT-004` covers the source half in a test process. The
metadata half depends on the exports in rehearsal 1, and the credential half
depends on rehearsal 4.

**What no rehearsal here can establish:** that a second operator can obtain the
WAL at all. It lives in storage the current operator controls, and this
repository contains nothing that changes that.

### Result, 2026-08-25

**Recovery passes in the test process**, through the three tests rehearsal 3's
step 3 names: the WAL rebuilds the repository and re-derives receipts a
database lost, the rebuild path reads no mirror, and the mirror restores source
without restoring the push record.

**The limit above is now measured rather than asserted, and it is stronger than
it reads.** The WAL adapter is `OpenAgents.Forge.WAL.Gcs` against one bucket in
the operator's own cloud project, with uniform bucket-level access, so reaching
it needs a grant only the current operator can make. That bucket has no object
versioning; soft delete retains a deleted object for seven days and nothing
longer. So the storage keeps no history of itself, and an operator who rewrote
an entry a week ago leaves no earlier copy in it. The only commitment outside
that bucket is the anchor at `/.well-known/openagents-forge-anchor.json`,
served by the same operator and witnessed by nobody (#151). A reader who kept a
copy of it can refute a later rewrite; a second operator starting from scratch
cannot.

## 6. Partial export

**Proves:** an export that cannot return everything says so rather than
returning a shorter document that reads as complete.

### Steps

1. Read the export document's `"bounds"` and every `*_truncated` flag. Each
   collection publishes its own cap; a truncated collection is flagged, and Box
   run output reports the full byte size alongside the capped bytes.
2. Read `"not_included"`. It names the families the document does not carry and
   why. Reputation attestations left that list when #171 bound an attestation
   subject to an account; they now travel under `"repository_work"`, and only a
   subject the account holds a `linked` claim on reaches the document.
3. Compare against `OpenAgents.DataRights.ExportInventory`, which `EXIT-001`
   enforces against the surface in both directions, and against the same
   counts published at `GET /api/status` under `independence.export`.

### Result, 2026-08-25

**Step 3 passes against the live forge.** `GET /api/status` publishes 35
families — 24 portable, 0 partial, 1 blocked, 10 not user data — with the
`trace` family as the one declared gap, and the deployed ledger reports the
same split and no drift.

**Step 3 fails against `main`.** The same comparison, run in the test suite,
reports `unclassified: [:response]`: `POST /api/v1/responses` reached the route
authority without a ledger entry. That is `EXIT-001`'s
derived coverage failing the build, which is what it is for. #252 carries the
decision it forced: the stub records nothing, so the family is
`not_user_data`, and the entry says it is revisited when a provider stands
behind the route.

**Steps 1 and 2 pass, exercised through the route against a local forge**
rather than a live session. The document carries a `bounds` map of fourteen
caps, ten `*_truncated` flags across five collections, and a `"not_included"`
list naming four families with a mechanism and a reason each. The sealed
variant returns an `age-encryption.org/v1` body that decrypts to the same
bounds.

**One flag was observed positive, and no committed test does that.** Every
`*_truncated` assertion in the suite is a `refute`, so the claim this rehearsal
exists to check had no proof that could fail for it. A Box run of 70,000 bytes
exports 65,536 with `output_truncated: true` and `output_byte_size: 70000`. The
observation lives in `docs/2026-08-25-forge-exit-rehearsals-2-to-6.md` rather
than in a test, so the proof gap remains.

## What these rehearsals do not cover

- **Withholding.** No rehearsal detects an operator who serves nothing or
  serves stale state.
- **Confidentiality.** No export is encrypted to a key the recipient holds, and
  no column in this repository is encrypted at rest (#178).
- **Attribution of operator reads.** No operator read is audited, so no
  rehearsal can show one did not happen.
