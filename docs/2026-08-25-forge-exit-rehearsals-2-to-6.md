# Forge exit rehearsals 2 through 6, performed

**Date:** 2026-08-25
**Issue:** #180
**Runbook:** `docs/forge-exit-rehearsals.md` defines the six rehearsals. This
document records what running five of them produced.
**Companion:** `docs/forge-operator-independence.md` states the trust boundary
they rehearse against.

Rehearsal 1 was performed on 2026-08-23, failed, and was filed as #179. The
other five had never been run outside the test suite. This record covers
rehearsals 2 through 6 against the live forge on revision
`46cf8a5aea3791936c22e82c145a9a8dd734374d`, deployed on all three fleet nodes.

## How to read this record

Every rehearsal is split into what ran against the live forge and what ran
against a forge a test process builds. The split matters, because #179 exists
precisely because six invariants were green against a forge the test built
while the live one could not serve a full clone. A claim proven only in a test
process is labeled as such here rather than being allowed to stand for the
live one.

Rehearsals must be read-only against production. Two documented steps mutate
state — rehearsal 3's `rebuild/1`, which discards a projection, and every
tamper in rehearsal 2's step 2 — so both were performed locally and are
labeled local. Nothing in this record deleted a repository, force-pushed,
mirrored, rotated a credential, or wrote to the WAL.

## Summary

| Rehearsal | Verdict | Defects filed |
| --- | --- | --- |
| 2. Detect a forged, missing, reordered, or mismatched receipt | Pass, with one new defect | #251; #190 still reproduces |
| 3. Mirror divergence | Pass, and it confirms #188 exactly | none new |
| 4. Key rotation | Pass in the test process, one deployment gap | #253 |
| 5. Operator loss | Recovery passes; the WAL remains unobtainable | none new |
| 6. Partial export | Pass live, red on `main` | #252 |

Three defects were filed. None of them was repaired inside this record.

## Rehearsal 2: detect a forged, missing, reordered, or mismatched receipt

### Step 1, live: the log and the projection agree

On one fleet node:

```
OpenAgents.Forge.Verification.verify("OpenAgentsInc/openagents.com")
#=> {:ok,
#=>  %{repo: "OpenAgentsInc/openagents.com",
#=>    storage_key: "ecd89cf6-f602-479f-9f47-266307345aaa",
#=>    entries: 382,
#=>    chained_from: 279,
#=>    head: %{seq: 381, link: "f663eb135c5fd51177024b803b0d7732930ae9a643fc9a8e7022d963a36e4949"},
#=>    findings: []}}
```

Reading the log directly gives the same shape: 382 entries, 103 of them
carrying a link, which is the contiguous suffix 279 through 381. Entries below
279 predate the chain, which `EXIT-005` calls history rather than tampering.

**Verdict: pass.**

### Step 1, live: #190 still reproduces

The rehearsal tells an operator to pass `{storage_key}`. The value the forge
offers for that placeholder is still wrong:

```
OpenAgents.Forge.Repos.allowed_repos()
#=> ["openagents.com"]

OpenAgents.Forge.Verification.verify("openagents.com")
#=> {:error, %{entries: 0, storage_key: "openagents.com",
#=>            findings: [%{code: "wal_unreadable", detail: %{"reason" => ":not_found"}}]}}
```

`verify/2` now accepts an `owner/name` path, which is #190's first acceptance
criterion and the reason step 1 above works at all. The other two are
outstanding. `allowed_repos/0` still returns a name no verifier can use, and
`/var/lib/openagents/forge/repos` still holds `openagents.com.git` beside the
six UUID-keyed directories that serve real repositories. An operator following
the runbook literally still reaches the report that means "your write-ahead log
is missing" for a log that is intact.

**Verdict: partial, tracked by #190.** No new issue.

### Step 3, live: the published anchor

`GET /.well-known/openagents-forge-anchor.json` answers `200`. The document
fetched over HTTPS before the check carried `anchor_seq: 2`, `published_at:
2026-08-25T13:52:41Z`, `signed: false`, `witnessed: false`, and this
repository at `head_seq: 375`, `head_link: "19c7a2c5…"`, `chained_from: 279`,
over 376 entries.

By the time the check ran the log had advanced past that sequence, which is
what makes the check meaningful: the anchor commits to a prefix, and the
verifier was asked about it afterwards.

| Anchor supplied | Result |
| --- | --- |
| `%{seq: 375, link: "19c7a2c5…"}`, the published value | `{:ok, findings: []}` |
| The same sequence with one hex digit changed | `anchor_mismatch`, naming the anchored and recorded values |
| `%{seq: 100, …}`, below `chained_from` | `anchor_unreachable`, `"entry carries no link"` |
| `%{seq: 99_999_999, …}` | `anchor_unreachable`, `"no entry at this sequence"` |

The option is honored rather than accepted and ignored, and the two
unreachable cases are distinguished by reason rather than collapsed.

**Verdict: pass.**

### Step 2, local: each finding code

Step 2 asks that each way the served state can disagree with the record be
reported distinctly. Producing those disagreements means tampering with a
repository, so this ran against a forge the test process builds:

```sh
mix test test/openagents/forge/independence_test.exs
```

Thirty-seven tests, all green. They name each code the step lists:
`entry_digest_mismatch` from a rewritten entry, `entry_sequence_broken` from a
removed one, `entry_object_missing` from an entry the store cannot produce,
`served_refs_diverged` from a ref moved or added without a push,
`object_missing` and `object_unreachable` from a lost cache and an unwalkable
history, and `chain_link_mismatch` and `chain_link_missing` from a rewrite that
leaves the chain alone and a link removed mid-log.

**Verdict: pass, in the test process only.** No tamper was performed against
the live forge, and this record does not claim one was.

### New defect: the three nodes disagree, and lag reads as tampering

Running step 1 on one node passes. Running it on all three at the same moment
gives three different answers.

| Time (UTC) | Repository | Node A | Node B | Node C |
| --- | --- | --- | --- | --- |
| 14:38–14:40 | `OpenAgentsInc/openagents.com` | clean, 382 entries | diverged, 383 | clean, 383 |
| 14:38–14:40 | `OpenAgentsInc/openagents` | diverged | clean | diverged |
| 14:57–14:58 | `OpenAgentsInc/openagents.com` | clean, 391 | clean, 392 | diverged, 393 |
| 14:57–14:58 | `OpenAgentsInc/openagents` | diverged | clean | diverged twice |

"Diverged" is `served_refs_diverged` plus `object_missing` — the two findings
that mean the forge is serving something other than what was pushed.

The cause is that the WAL is shared and the projection is not. The adapter is
`OpenAgents.Forge.WAL.Gcs` against one bucket; the bare repositories sit on
each node's own disk. A node that has not replayed an entry yet is
indistinguishable, to `verify/2`, from a node whose projection was altered.

It converges without help. Entry 136 of `OpenAgentsInc/openagents` was written
at 14:32:33Z; node A still reported the divergence at 14:38:25Z and
was clean by 14:42:35Z, with its WAL head and its on-disk `refs/heads/main`
both reading `4773472f`. Eight consecutive `git ls-remote` calls against the
same repository returned one sha, so no client-visible flapping was observed.

This matters most for #179, whose third acceptance criterion asks for a
scheduled verification pass publishing its findings. Built today, that pass
would publish tampering findings for a healthy forge most of the time.

Filed as **#251**.

## Rehearsal 3: mirror divergence

### Step 1, live: compare heads

```sh
git ls-remote https://openagents.com/OpenAgentsInc/openagents.com.git > forge-refs.txt
git ls-remote https://github.com/OpenAgentsInc/openagents.com.git > gh-refs.txt
diff <(sort forge-refs.txt) <(sort gh-refs.txt)
```

Twenty-five refs on each side, byte-identical, `refs/heads/main` at
`e57f5ea8b1666ccb69fc4c626f54cf41b34a0ebe` on both.

**Verdict: pass.** Ref maps agree.

### Step 1, live: histories do not agree, and #188 is confirmed at today's numbers

Identical ref maps are not identical history. Both sides were cloned in full:

| Source | Commits on `main` | `git fsck` | Root commit | Holds `c91327d6` |
| --- | --- | --- | --- | --- |
| The forge | 423 | clean | `eda094c6` | no |
| GitHub mirror | 730 | clean | `a352f78e` | yes, with 307 commits behind it |

The forge clone now succeeds, which is #179's first acceptance criterion. It
carries a `.git/shallow` file naming five boundaries, so the clone is honest
about where history stops rather than aborting. `git fsck` is clean.

The 307-commit gap is exactly what #188 records: 730 minus 423. Those commits
are on the mirror and in no WAL, so no rebuild produces them. For everything
pushed since the seed the forge is canonical and the mirror is lossy; for
everything before it the relation is inverted.

### Step 2, live: a mirror is configured

The live node answers:

```
Application.get_env(:openagents, :forge_mirror_urls, %{}) |> Map.keys()
#=> ["openagents.com"]
```

and `GET /api/status` publishes `forge.mirror` as
`{"repo": "openagents.com", "state": "current", "lagging_minutes": null}`.

Both halves of #188's first finding hold. `INVARIANTS.md` and `CLAUDE.md` have
since been corrected, and `test/openagents/forge/independence_test.exs` carries
"does not claim a mirror is unconfigured while runtime configures one", which
reads the configuration rather than asserting the empty default. That is #188's
first acceptance criterion met; its second and third remain open.

**Verdict: pass, and it reproduces #188.** No new issue.

### Step 3, local: recovery comes from the WAL

Step 3 calls `OpenAgents.Forge.Sync.rebuild/1`, which discards the local bare
repository and re-materializes it from sequence zero. That is a mutation, so it
was **not run against production**. Its behavior was exercised locally instead,
by three tests in `test/openagents/forge/independence_test.exs`:

- "the WAL rebuilds the repository and re-derives receipts the database lost"
- "the rebuild path never reads the mirror"
- "the mirror restores source and cannot restore the push record"

All three pass.

**Verdict: pass, in the test process only.** Whether `rebuild/1` succeeds
against the live 423-commit projection is untested, and this record does not
claim it.

## Rehearsal 4: key rotation

The runbook records this rehearsal's executable proof as "None". That is stale.
`test/openagents/forge/key_rotation_test.exs` exists and covers both halves of
what #180 asks for. Twelve tests, all green.

### Local: no rotation invalidates a receipt

- "the WAL chain link is unkeyed and reproducible from the entry alone"
- "the verifier was compiled against no secret and no vault"

A forge receipt depends on no key, so the first half of #180's contract holds
by construction rather than by procedure.

### Local: a rotation in the wrong order is refused

Four tests cover the reputation issuer key's ordering rule:

- retiring forward keeps an attestation verified and the successor issues
- retiring backward is refused, and the refusal names the attestation it would
  have unverified (#191)
- a key that signed nothing is bounded by its own activation
- a future-dated retirement beyond the clock-skew allowance is refused

There is no override, which is the point: a backdated retirement is the single
`UPDATE` that silently unverifies published signatures.

### Local: the three vaults rotate differently, and each says how

- the GitHub vault opens envelopes sealed under a retired key
- it refuses an envelope whose key left the keyring
- a GitHub key rotation does not orphan the machine pairing vault (#192)
- the voice recording vault has no keyring, so its key cannot rotate without
  stranding what it sealed

### Live, read-only: what is actually deployed

Read from the node without printing any key material:

| Secret | Live state |
| --- | --- |
| `GITHUB_TOKEN_ENCRYPTION_KEY` | set, key id `production-legacy-v1` |
| `GITHUB_TOKEN_DECRYPTION_KEYS_JSON` | empty |
| `MACHINE_TOKEN_ENCRYPTION_KEY` | unset |
| `VOICE_RECORDING_ENCRYPTION_KEY` | set, and a different key |
| Forge operator token | configured |
| Admitted reputation issuer keys | none |

Three of these are worth stating plainly.

**The pairing vault is not separated in production.** With
`MACHINE_TOKEN_ENCRYPTION_KEY` unset, the runtime falls through to the boot
bridge and configures the pairing vault with the GitHub vault's active key. The
two configured values hash identically on the node. #192's fix is deployed and
correct; the secret it needs was never provisioned, so the bridge meant to last
one deploy is the production configuration. `VAULT-001` says each vault seals
under its own key, and two of the three currently do not. Filed as **#253**.

**No key has ever been rotated here.** The GitHub retired keyring is empty and
the active key id is `production-legacy-v1`, so the documented rotation — add
the old key to the keyring, activate the new one, rewrap with
`OpenAgents.Accounts.rotate_github_tokens!/0` — has never run against
production. That is a fact rather than a defect, and it is the reason this
rehearsal's live half is an inventory instead of a rotation.

> **Later the same day (2026-08-25):** the pairing-vault row above is no longer
> current. `MACHINE_TOKEN_ENCRYPTION_KEY` is provisioned in Secret Manager,
> `ops/deploy/fleet-startup.template.sh` exports it, and a re-read of all three
> fleet nodes answers `machine_set=true` and `same_as_github=false`, with all
> four vault keys set and pairwise distinct. `RuntimeConfig.validate/1` now
> refuses a staging or production boot on a duplicate vault key, so the reading
> above cannot recur unnoticed. #253 records the gap and its close. The rest of
> this inventory stands: no key has been rotated here.

**No attestation has been signed here.** `OpenAgents.Reputation.keys()` returns
none on the live node, so the issuer rotation path has no production
population. The ordering rule is proven in the test process and has never been
exercised against a real attestation.

**Verdict: pass in the test process; one deployment gap, filed as #253.** No
key was rotated against production, and this record does not claim one was.
Rehearsal 4 now has an executable proof, which closes #180's third acceptance
criterion.

## Rehearsal 5: operator loss

### Local: a second operator recovers from the WAL

`rebuild/1` re-materializes a repository from sequence zero with no mirror
input, and the receipts a database lost are re-derived from the log. Both are
proven in the test process by the three tests rehearsal 3's step 3 names. That
is the source half, and it holds.

The metadata half is rehearsal 6's export, and the credential half is rehearsal
4's inventory. Both are recorded above.

### Live, read-only: what a second operator cannot obtain

The runbook says the WAL "lives in storage the current operator controls, and
this repository contains nothing that changes that". Read from the node and
from the storage API, that is exact, and it is more specific than the sentence
suggests:

- The adapter is `OpenAgents.Forge.WAL.Gcs`, against the bucket
  one bucket in the operator's own cloud project, in one region.
- The bucket has uniform bucket-level access, so reaching it requires an IAM
  grant only the current operator can make. There is no anonymous read path and
  no second copy anywhere a stranger can reach.
- The bucket has **no object versioning**. Soft delete retains a deleted object
  for seven days and nothing longer. An operator who rewrote an entry a week
  ago leaves no earlier copy in the bucket for anyone to compare against.
- The bare repositories are node-local, on each node's own disk, so they are a
  projection rather than a second copy of the record.

So the honest statement is stronger than "the operator controls the storage".
The storage keeps no history of itself. The only thing outside it that commits
to the log's contents is the anchor published at
`/.well-known/openagents-forge-anchor.json`, and that document is served by the
same operator and witnessed by nobody — it says so itself, and
`GET /api/status` reports `anchor_witnessed: false`. A reader who kept a copy
of it can refute a later rewrite; a reader who did not cannot, and neither can
a second operator.

**Verdict: recovery passes in the test process. The rehearsal's stated limit
holds and is now measured rather than asserted.** No new issue: #151 already
carries the witness.

## Rehearsal 6: partial export

### Steps 1 and 2, local: the document says what it leaves out

Performed through the route a person uses, against a forge the test process
builds, because the live route requires a session and this record does not
claim to have opened one. `GET /data/export/account` answers `200` and returns
a document with fifteen top-level keys.

`"bounds"` names fourteen caps:

```json
{"attestations": 5000, "box_run_output_bytes": 65536, "box_runs": 2000,
 "deployments": 2000, "forum_posts": 10000, "forum_tips": 2000,
 "forum_topics": 2000, "issue_dependencies": 5000, "pull_requests": 5000,
 "push_receipts": 10000, "stack_entries": 10000, "stacks": 2000,
 "thread_events": 10000, "threads": 1000}
```

Ten `*_truncated` flags travel with the collections they bound, across
`boxes`, `deployments`, `forum`, `push_receipts`, and `threads`.

`"not_included"` names four families with a mechanism and a reason each:
`conversation` through `GET /data/export` and `GET /data/export/atif`,
`repository_content` through the authenticated Git transport,
`repository_identity` for a repository the account can no longer read, and
`forum` for posts under an unclaimed legacy `actor_ref`.

The sealed variant behaves the same. `GET /data/export/account?recipient=…`
returns a body beginning `age-encryption.org/v1`, with a `.json.age` filename,
and decrypts to the same `bounds`.

**Verdict: pass.**

### Step 1, local: a flag actually turns true

Every `*_truncated` assertion in the committed suite is a `refute`. Nothing
proved the positive case, so the central claim — that a document which cannot
return everything says so — had no proof that could fail for it.

A Box run with 70,000 bytes of output was seeded and read back through the
route:

| Measurement | Value |
| --- | --- |
| Output produced | 70,000 bytes |
| `bounds.box_run_output_bytes` | 65,536 |
| Output exported | 65,536 bytes |
| `run.output_truncated` | `true` |
| `run.output_byte_size` | 70,000 |

The document reports the full size beside the capped bytes and flags the cut.

**Verdict: pass.** The proof gap is real and remains: this observation lives in
this record rather than in a committed test, so nothing turns red if the flag
stops being set. `docs/2026-08-24-invariant-proof-audit.md` is the register for
that class of residue.

### Step 3, live: the ledger and the disclosure agree

`GET /api/status` publishes:

```json
"export": {"families": 35, "portable": 24, "partial": 0, "blocked": 1,
           "not_user_data": 10,
           "gaps": [{"family": "trace", "issue": 217, "status": "blocked"}]}
```

and the deployed `OpenAgents.DataRights.ExportInventory` reports the same 35
families with the same split and the same single gap. `api_family_drift/0`
returns `%{stale: [], unclassified: []}` on the node.

**Verdict: pass, live.**

### Step 3, on `main`: the coverage proof is red

The same comparison fails on `main` at `2a9bd5e`:

```
assert ExportInventory.api_family_drift() == %{unclassified: [], stale: []}
left:  %{stale: [], unclassified: [:response]}
```

`bf115c0` added `POST /api/v1/responses` to `OpenAgentsWeb.ApiRouteAuthority`
with the family `:response` and no ledger entry. This is `EXIT-001`'s derived
coverage doing what it exists to do — a family reached `/api/v1` without anyone
deciding whether a user can export it, and the build failed. What remains is
the decision. Filed as **#252**, and answered in a separate commit rather than
inside this record: `OpenAgentsWeb.ResponsesController` reaches no repo and no
schema, so the family is `not_user_data` with a note saying the entry is
revisited the day a provider stands behind the stub.

**Verdict: pass against the live forge, fail against `main` when the rehearsal
ran.**

## What these rehearsals still do not cover

The runbook's own list is unchanged and still accurate: withholding,
confidentiality, and attribution of operator reads. Two additions from
performing them:

- **No tamper was performed against the live forge.** Every finding code in
  rehearsal 2's step 2 is proven in a test process. The live half proves the
  verifier runs and reports clean, not that it would report a real tamper here.
- **No key was rotated and no projection was rebuilt against production.**
  Rehearsals 4 and 5 measured what is deployed and proved the procedures
  elsewhere. A rehearsal that cannot safely run its own destructive step
  against production is a rehearsal with a permanent gap, and saying so is
  better than implying the step was taken.
