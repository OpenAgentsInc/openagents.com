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
| 1. Restore a repository and its work history | `EXIT-004`, `EXIT-001` | 2026-08-23 — **failed**, #179; re-run 2026-08-24 — **still failed**, #187 |
| 2. Detect a forged, missing, reordered, or mismatched receipt | `EXIT-002`, `EXIT-005` | 2026-08-24 — **performed, and the result is worse than a failure**: #187, #190 |
| 3. Mirror divergence | `EXIT-003` | 2026-08-24 — **performed, failed**: #188, #189 |
| 4. Key rotation | `test/openagents/forge/key_rotation_test.exs` | 2026-08-24 — **performed, partly failed**: #191, #192 |
| 5. Operator loss | `EXIT-003` | 2026-08-24 — **performed as far as it can be**; the blocking half is named below |
| 6. Partial export | `EXIT-001` | 2026-08-24 — **performed, failed**: #187 |

All six have now been run against the live forge. Five of them found something,
and one finding is common to three of them: `main` is 57 commits ahead of the
deployed revision `6d421b3c7ffe`, and the exit surfaces #94 audits are all in
those 57 commits. #187 carries that.

The general lesson is the one #179 already taught, now with five more
instances. Every invariant `EXIT-001` through `EXIT-006` was green throughout,
because each runs against a forge the test process builds. A rehearsal runs
against the forge people use, and that is the entire difference.

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
from it.

### Re-run, 2026-08-24

**Step 1 failed again, and it will keep failing until a release is promoted.**
The repair is on `main`; the live forge runs `6d421b3c7ffe`, which predates
it. Verbatim:

```
$ git clone https://openagents.com/OpenAgentsInc/openagents.com.git restored
Cloning into 'restored'...
remote: error: Could not read c91327d60c520d11133ddcc6cb3304784f2f0481
remote: fatal: Failed to traverse parents of commit eda094c6ae9f100060b96cd93bad9e4ecd117e94
remote: aborting due to possible repository corruption on the remote side.
fatal: early EOF
fatal: fetch-pack: invalid index-pack output
```

Four of the five branches #179 recorded still fail at depth 2:
`codex/github-backed-repositories`, `codex/posthog-integration`,
`components-gallery`, and `repos-ui`. `codex/admin-posthog-analytics` now
succeeds, because something pushed across its boundary in the interval.

**One sentence of #179's diagnosis is wrong, and rehearsal 2 is what found
it.** #179 says the seed "was written before WAL entries carried a `shallow`
key. The log therefore records no boundary." The live WAL says otherwise. Its
seq 0 entry carries a `shallow` key naming five boundary commits, `eda094c6`
among them, and the served projection has no `shallow` file at all:

```
File.exists?("/var/lib/openagents/forge/repos/ecd89cf6-….git/shallow")
#=> false
```

The log holds the boundary; the projection does not. The deployed replay does
write the graft — `OpenAgents.Forge.Sync.write_shallow_boundaries/2` exists at
`6d421b3c7ffe` — but only while applying an entry, and this cache was
materialized before that code existed and has applied nothing since that would
rewrite it. So the repair `main` carries is the right one, and the reason it is
needed is a stale projection rather than a silent log.

That distinction matters for what is recoverable. The graft is recoverable from
the WAL, so the repository becomes cloneable, with history that honestly stops
at the boundary. The 307 pre-seed commits are not in the WAL and are not
recoverable from it. See rehearsal 3 for where they are.

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

### Result, 2026-08-24

Performed on `sarah-fleet-1` through
`docker exec openagents /app/bin/openagents rpc`. Steps 1 and 2 ran. Step 3
could not.

**Step 1 does not work as written.** The rehearsal says `{storage_key}` and the
forge answers with a name:

```
> OpenAgents.Forge.Repos.allowed_repos()
["openagents.com"]

> OpenAgents.Forge.Verification.verify("openagents.com")
{:error, %{entries: 0, repo: "openagents.com",
           findings: [%{code: "wal_unreadable", detail: %{"reason" => ":not_found"}}]}}
```

`wal_unreadable` is what a verifier says when the write-ahead log is gone. The
log is intact; the name is wrong. The served repository is keyed by a UUID, and
a stale bare repository sits under the name holding one ref at a commit `main`
passed long ago. Filed as #190.

**Step 2 reports clean on a repository that cannot be cloned.**

```
> OpenAgents.Forge.Verification.verify("ecd89cf6-f602-479f-9f47-266307345aaa")
tag=:ok
entries=275
finding_count=0
codes=%{}
```

Zero findings, at the same hour a full clone of that repository aborts. This is
the sharpest available statement of why rehearsals exist. The deployed verifier
checks that every ref tip resolves, and every ref tip does; it does not walk
the tips into their ancestors, because the walk is part of the `EXIT-004`
amendment on `main`. A green verifier and an unservable repository, at the same
moment, on the same node.

**The chain `EXIT-005` describes is not running.** Of the 275 entries in the
live log, **none carries a link** — including the entry written twelve minutes
before the check:

```
> entries=275 linked=0
> last=%{"format" => "receive_pack", "object" => "entries/00000274-3f1807e0e409",
         "principal" => "user:af9e…", "pushed_at" => "2026-08-24T03:53:33.604547Z", "seq" => 274}
```

Confirmed independently: `OpenAgents.Forge.WAL.chain_link/2` and `entry_link/1`
do not exist on the deployed build, with the module loaded first, because
`function_exported?/3` answers `false` for a module nobody has loaded and that
is an easy way to draw the wrong conclusion.

**Step 3 could not be performed at all.** The deployed `Verification.verify`
has arity 1:

```
> OpenAgents.Forge.Verification.__info__(:functions) |> Keyword.get_values(:verify)
[1]
```

There is no `:anchor` option to pass, and there would be nothing to pass to it:
an anchor is a `link`, and no entry has one. The one check that distinguishes
`EXIT-005`'s tamper-evidence from `EXIT-002`'s "the operator agrees with the
operator" is unavailable on the live forge. `Application.get_env(:openagents,
:forge_wal_anchor)` is `nil`, which is what `EXIT-006` would publish if
`EXIT-006` were deployed; `OpenAgents.Forge.Independence` does not load on the
node either. Filed as #187.

**What this rehearsal proves today:** that `verify/1` runs against production
storage without a database and reports the shape it promises. That is real and
it is less than the rehearsal claims. Every disagreement it can detect other
than the five ref-and-entry findings is unavailable here.

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

### Result, 2026-08-24

**Step 1: no divergence, and that is not the good news it sounds like.** The
two ref maps are identical — 25 refs, same shas, `refs/heads/main` at
`773ad680` on both.

**Step 2 contradicts the contract.** `EXIT-003` states as an operational fact
that `:forge_mirror_urls` "is empty in `config/config.exs` and set by no
environment, so no mirror runs today", and `CLAUDE.md` repeats it. The live
node disagrees:

```
> Application.get_env(:openagents, :forge_mirror_urls, %{}) |> Map.keys()
["openagents.com"]
```

`GET /api/status` says so too, publishing `forge.mirror` as
`{"repo": "openagents.com", "state": "current"}`, which
`OpenAgents.Forge.MirrorWatch` emits only for a configured repo. A mirror runs,
and `mirror_now/1` is a force push of every ref. Filed as #188.

**And the mirror is the only complete copy of half this repository.**

| Source | `main` commits | `git fsck` | Holds `c91327d6` |
| --- | --- | --- | --- |
| GitHub mirror | 603 | clean | yes |
| The forge | 296, from the seed forward | full clone aborts | no |

307 commits — 51% of `main` — exist on GitHub and nowhere else this forge can
reach. They are not in the WAL, so no rebuild produces them. `EXIT-003` says
recovery comes from the WAL and the mirror is strictly lossy; for the pre-seed
history the relation is inverted, and the mirror is strictly richer. That is
the outcome `EXIT-003` exists to prevent, arrived at from a direction the
invariant does not watch: not a fallback someone added to the recovery path,
but a projection that never held the history in the first place. Also #188.

**Step 3 could not be performed, because the function does not exist.**

```
> OpenAgents.Forge.Sync.__info__(:functions) |> Keyword.keys()
[:ensure_cluster_fresh, :ensure_fresh, :ensure_fresh!, :replay_missing, :with_repo_lock]
```

`OpenAgents.Forge.Sync.rebuild/1` is not on the deployed build and is not on
`main`. This document and #179 both instruct an operator to run it. Filed as
#189.

## 4. Key rotation

**Proves:** that no forge receipt depends on any key this forge holds, so no
rotation can invalidate one; and, for each key-like secret, whether rotating it
loses data and whether the wrong order is refused.

**Executable proof:** `test/openagents/forge/key_rotation_test.exs`, added by
#180. This rehearsal had none until then.

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

### Result, 2026-08-24

The first half holds everywhere. The second holds in one family of four.

| Family | Rotation loses nothing | Wrong order refused |
| --- | --- | --- |
| Forge operator token | yes | not applicable — there is no order |
| Account `oa_pat_` tokens | yes | not applicable |
| Reputation issuer key | forward, yes | **no** — #191 |
| GitHub token vault | yes | yes |
| Machine pairing vault | **no** — #192 | no |
| Voice recording vault | **no** | no |

**No forge receipt depends on a key at all**, which makes the positive claim
true and worth stating plainly rather than triumphantly. `OpenAgents.Forge.WAL`'s
chain link is unkeyed `sha256` over a domain tag and the entry's own fields,
and `OpenAgents.Forge.Verification` was compiled against no vault, no
`OpenAgents.ApiTokens`, and no `OpenAgents.Reputation`. The proof rotates every
key-like secret in the application underneath a computed link and asserts the
link is unmoved. A push made with the operator token records the literal
`operator:forge-token`, which is written at push time rather than derived from
the secret, so no rotation makes a past push attributable to a person or takes
attribution away.

**The reputation issuer key fails the second half.** `retire_key/2` accepts any
timestamp and validates it against nothing. Retiring a key at a moment at or
before an attestation it already signed flips that attestation to
`"verified" => false` while `"signature" => %{"valid" => true}` — a valid
signature over an unaltered claim, reported as unverified, by one `UPDATE`
against a row the operator controls. The forward edge *is* guarded:
`require_active_key/2` refuses issuance under a key that is not yet active.
Only retirement is open. Filed as #191.

**The machine pairing vault fails the first half, and the coupling is not
written down anywhere.** `OpenAgents.Machines.TokenVault.key/0` reads
`:github_token_encryption_key` — the GitHub vault's *active* key — and its
envelope carries no key id and consults no keyring. So the documented GitHub
rotation in `docs/github-auth-plan.md`, performed in the documented order,
makes every outstanding pairing ciphertext permanently unopenable. The blast
radius is bounded: pairings live ten minutes and both terminal transitions null
the column, so at most ten minutes of unclaimed pairings are lost. Filed as
#192. `OpenAgents.Voice.RecordingVault` has the same shape with its own key and
no rewrap path; `test/openagents/voice/recordings_test.exs:319` already pins
that a wrong key fails closed, so what was missing was the statement that
rotating it is unrecoverable rather than the behaviour.

**The GitHub token vault is the one that gets this right**, and it is worth
saying why rather than only that it does. The key id is inside the envelope and
bound into the AAD, up to sixteen prior keys stay readable, `rotate_github_tokens!/0`
rewraps inside one transaction, and an invalid keyring raises at boot in `:prod`.
Performed in the wrong order it fails closed and the rewrap rolls back, rather
than writing a row nobody can open.

Both failures are pinned by tests that name their issue, so a fix turns the
test red instead of passing unnoticed. Each pin was mutation-checked by
implementing the fix and confirming the pin failed.

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

### Result, 2026-08-24

Performed as far as it goes, which is not far, and the boundary is now concrete
rather than abstract.

**What a second operator would need, named exactly.** The WAL adapter is
`OpenAgents.Forge.WAL.Gcs` and the bucket is `sarah-forge-wal`, in the Google
Cloud project the current operator owns. There is no second custodian, no
escrow, no copy anywhere else, and no mechanism in this repository by which one
could be established. A second operator starting from nothing obtains **no
refs, no objects, no sequences, no principals, and no push times**, because all
of it lives behind one IAM boundary.

**What that leaves them.** The GitHub mirror, which carries every commit, tree,
blob, tag, and advertised ref and no record of who pushed what or when — and
which, as rehearsal 3 found, currently carries 307 commits of history the WAL
never held. So a second operator restoring from the mirror alone would today
recover *more source* and *no provenance*: a complete-looking repository with
no evidence attached to any of it. `EXIT-003` proves both halves of that trade
in a test process; this rehearsal is where it becomes a fact about this forge.

**The metadata half was not exercised**, because the account export it depends
on returns `404` on the live forge — see rehearsal 6. **The credential half was
not exercised**, because it depends on rehearsal 4, which found two families
that do not survive rotation at all.

**This rehearsal cannot be completed from here.** Completing it needs a WAL
copy held somewhere the current operator does not solely control, which is an
owner action and an infrastructure decision, not a code change. It is the same
missing thing `#151` and `#168` name for the anchor, one level up: an anchor
proves the log was not rewritten, and a second custodian is what makes the log
obtainable at all. Neither exists today and no rehearsal changes that.

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

### Result, 2026-08-24

**Step 1 could not be performed. The route does not exist on the live forge.**

```
$ curl -s -o /dev/null -w '%{http_code}\n' https://openagents.com/data/export/account
404
$ curl -s -o /dev/null -w '%{http_code}\n' https://openagents.com/data/export
302
```

`302` is the sign-in redirect, which is what an authenticated route answers to
an anonymous caller. `404` is what a route that was never compiled answers.
`GET /data/export/account` landed in `b061b99`, after the deployed revision.

**Step 3 could not be performed either**, for the same reason one level up:
`/api/status` publishes no `independence` section, because
`OpenAgents.Forge.Independence` is not on the deployed build. So the counts
this step says to compare against do not exist, and neither does the
`independence.export.gaps` list. Filed as #187.

**What was exercised instead.** The bounds and `not_included` properties this
rehearsal checks are proven in
`test/openagents/data_rights/account_export_test.exs` against the ledger in
both directions, and that proof is green. What a green proof cannot tell you is
whether the route is reachable, and that is the whole content of this result:
`EXIT-001` is the most thoroughly proven of the six exit invariants, and the
document it proves cannot be downloaded from the forge it describes.

**One thing changed here rather than only being found.** #178 landed while this
rehearsal was being performed, so the route now accepts an `age` recipient and
returns a document encrypted to a key the operator does not hold. That widens
what step 1 will check once a release carries it: the export can now be taken
without the operator being able to read the file that carries it. The store it
was built from stays plaintext, which `GET /api/status` publishes beside it —
see `docs/2026-08-24-private-export-encryption.md`.

## What these rehearsals do not cover

- **Withholding.** No rehearsal detects an operator who serves nothing or
  serves stale state.
- **Confidentiality of the store.** The account export can now be encrypted to
  a key the recipient holds (#178), which protects the file and not the
  database it was read from. No column in this repository is encrypted at rest
  (#193), so the operator holds the plaintext every export is built from.
- **Attribution of operator reads.** No operator read is audited, so no
  rehearsal can show one did not happen.
- **The gap between a proven invariant and a deployed one.** Nothing reports
  it. Five of the six rehearsals above ran into it, and each found it by hand.
  #187.
