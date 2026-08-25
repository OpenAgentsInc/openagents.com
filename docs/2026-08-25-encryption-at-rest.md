# Which columns stop being server-readable, and what that would cost

**Date:** 2026-08-25
**Issue:** #193
**Parent:** #94
**Companion:** `docs/2026-08-24-private-export-encryption.md`
**Revised:** 2026-08-25, second pass. Section 8 records what changed and why
the first pass's answer was narrower than the question.

#178 asked whether a private export can be encrypted to a key the operator does
not hold. It can, and is. That decision deliberately left the other half open,
and #193 carries it: the store behind the export is plaintext PostgreSQL, and
`GET /api/status` publishes `independence.private_data.encrypted_at_rest` as
`false` so a reader who sees the export encryption also sees what it was built
from.

This document is the decision for the storage half.

## 1. The decision

**No content column is encrypted, the reason is written down rather than
implied, and the boolean that says so stops being a literal.**

Three things change:

- `encrypted_at_rest` is derived from `OpenAgents.Forge.AtRest` instead of
  being stated in `OpenAgents.Forge.Independence`. The private store is
  encrypted at rest exactly when no private column rests as plaintext, and the
  columns that do are named and proven plaintext against PostgreSQL.
- Every column whose name carries secret-shaped vocabulary is classified, and
  the population comes from `information_schema` rather than from a list.
  A migration that adds a plaintext token column fails on the day it lands.
- The ledger's claim is corrected. `EXIT-006` said "no Ecto column in this
  repository is encrypted at rest." Three are, and saying otherwise
  understated what the vaults already do while overstating how checkable the
  sentence was.

The published boolean does not move. It is still `false`, and it is still
`degraded?`'s at-rest axis. What moves is that it can now fail.

## 2. What is actually in the store

The inventory came first, because "encrypt the sensitive columns" is not a
decision until someone says which columns those are. Every migration in
`priv/repo/migrations/` was read, and every column the catalog reports under
secret-shaped vocabulary was classified. The result is narrower than the
issue's framing suggested.

**Reversible secret material rests in three columns, and all three are
sealed.** `users.github_token_ciphertext` under `OpenAgents.Accounts.TokenVault`,
`machine_pairings.token_ciphertext` under `OpenAgents.Machines.TokenVault`, and
`voice_recording_chunks.data` under `OpenAgents.Voice.RecordingVault`. Each has
its own key, which is what `VAULT-001` binds.

**Every other bearer credential rests as a one-way SHA-256 digest.** Personal
access tokens, agent tokens, computer tokens, inference grants, assignment
credentials, deployment workflow grants, device-flow codes, pairing codes, and
poll secrets. Nothing reverses these, so nothing seals them.

**External provider credentials never enter PostgreSQL at all.**
`scv_driver_accounts.secret_ref` is a pointer into Secret Manager;
`deployment_environments.secret_references` holds variable names.
`reputation_signing_keys.public_key` is the public half, and `RELEASE-002`
keeps the private half runtime-only.

So there was no plaintext secret column to encrypt. The gap #193 names is real,
but it is a gap in *content*, not in credentials.

## 3. The threat model, and why an operator key does not close it

Two designs are available and they protect against different adversaries. The
difference is the whole decision.

**A key the operator holds** protects a stolen dump, a stolen backup, and a
stolen disk. It protects against nothing else, because the operator decrypts at
will. This is exactly what the three vaults do, and `VOICE-012` already says it
in as many words: "the seal here defends against a stolen database, not against
the person who holds the key."

**A key only the account holds** protects against the operator. It also ends
every server-side read of that column.

Extending the first design across content columns would produce a status page
that says `encrypted_at_rest: true` while `operator_reads_source` is also true,
and a reader would take the pair to mean more than it does. `EXIT-006` exists to
keep that claim off the page. #178 rejected the same move on the export path for
the same reason, and rejecting it here is consistent rather than novel.

## 4. What the account would give up

Under an account-held key, for the columns that matter:

- **`messages.content`.** The conversation. It carries a `search_vector`;
  full-text search over your own history ends. So does server-side rendering,
  so does every projection that reads a message.
- **`voice_transcript_items.content`.** `VOICE-012` calls this the conversation
  record and says a recording never displaces it. Sealing the audio while this
  rests in plaintext beside it is worth naming as an asymmetry — a stolen dump
  gets the words either way — but sealing the transcript alone closes nothing,
  because `messages.content` holds the same words and is searched.
- **`issues.body` and `comments.body`.** Issue lists, search, cross-references,
  and the per-repository projections `TRANSPARENCY-001` publishes.

And key loss becomes permanent data loss. `docs/2026-08-24-private-export-encryption.md`
section 3 is the reason that objection decides storage and does not touch
exports: an export is derived, so a lost key costs one repeated download.
PostgreSQL is the record. There is nothing to re-derive it from.

That is the trade, stated plainly: an account that wants its issues encrypted
to a key this forge cannot read is asking for a forge that cannot list its
issues. Nobody has asked for that, and building it without being asked would
be choosing the cryptography over the product.

## 5. Options rejected

**Encrypt every content column under an operator-held key.** Rejected. It
protects a stolen backup, which the disk already does, and publishing it as
`encrypted_at_rest: true` would read as protection from the operator while
providing none. Same rejection as #178, same reason.

**Encrypt every content column under an account-held key.** Rejected, for now
and with the cost written down rather than waved at. It ends search, rendering,
and the transparency projections, and makes key loss permanent. A serious
version needs someone to ask for it and to accept section 4.

**Add `cloak` / `cloak_ecto` and an `Ecto.Type` per field.** Rejected on
mechanism as well as on threat model. This repository already has three vaults
with versioned framing, key identifiers, per-vault AAD, and a keyring for
rotation — `VAULT-001` binds the property that rotating one never unreads
another. `cloak_ecto`'s default is a single global keyring, which is the shape
`#192` found and fixed. Adding a dependency to get a weaker version of what is
already here would trade a proven property for a familiar name.

**Seal `voice_transcript_items.content` alone, since the audio beside it is
sealed.** Rejected in the first pass, and it was the closest call. **Overturned
in section 8** — the reasoning below proves the seal does not close the *threat*
while `messages.content` is searchable, which is true, and then wrongly
concludes that it is not worth doing. The asymmetry is real, but the
same words rest in `messages.content`, which is searched. Sealing one and not
the other would move a number without moving the threat model, which is the
failure mode this whole document is written against. It is recorded in section
4 rather than closed.

**Transparent disk encryption, and claim it.** Not rejected as a practice —
rejected as a claim. It protects a stolen disk and is invisible to this
repository, so nothing here can derive it and `EXIT-006` will not publish what
it cannot check.

## 6. What was proven, and how

`test/openagents/forge/at_rest_test.exs`.

The claim is not "the vaults have unit tests" — they did, and the columns were
still never checked. It is that PostgreSQL holds what this ledger says it
holds, so three kinds of assertion carry it:

1. **The sealed columns are ciphertext in the database.** Each of the three is
   written through the real application path — an OAuth token stored, a pairing
   approved, an audio slice appended — and then read back with raw SQL rather
   than through Ecto, because the schema's type layer is exactly what would
   hide the answer. The application still reads each value back, so the seal is
   a seal and not a loss.
2. **The plaintext columns are plaintext in the database.** The same read,
   expecting the opposite answer, so a column that quietly became sealed stops
   being published as a gap in the same commit.
3. **The population comes from `information_schema`.** Every secret-shaped
   column the catalog reports must be classified, and no column may be
   classified `:plaintext_secret`. That second assertion is the security
   contract; the first is what keeps it from going green on a population
   someone curated.

Four mutations were confirmed red and reverted:

- A classification removed, standing in for a migration that adds an
  unclassified column. The catalog-derived population caught it.
- `api_tokens.token_digest` reclassified `:plaintext_secret`. The security
  assertion caught it.
- `OpenAgents.Forge.Independence` reverted to a literal `false`. Comparing the
  two values **cannot** catch this, because `false` is the correct answer
  today, so the proof reads the compiled import table instead — the same
  technique `EXIT-002`, `EXIT-003`, and `export_recipient_encryption` use.
  This is the mutation that decided the shape of the test.
- `OpenAgents.Accounts.TokenVault.seal_with_metadata/1` made to return the
  plaintext. The raw-column assertion caught it.

One deliberate non-bite is worth recording. Shortening
`plaintext_private_columns/0` does not fail, and should not: the list is a
floor. A missing entry leaves `encrypted_at_rest?/0` at `false`, which is where
it already is, so an incomplete list understates the store rather than
flattering it. Completeness would only be load-bearing for a `true` claim, and
the first entry to disappear from that list will be the one that has to prove
it earned it.

## 7. What is still open

Sections 1 through 6 are the first pass and are kept as written. Section 8
revises them: four content columns are sealed now, and the list below is
narrower than it was. Read section 8 for the current state.

- **Some content columns are plaintext, and the operator reads them.** Section
  8.2 names each one and the query that keeps it readable. `/status` keeps
  publishing `encrypted_at_rest: false` while any of them remains, which is the
  outcome `EXIT-006` exists to produce.
- **No operator read is audited.** `ADMIN-001`. An access log the operator
  writes into the operator's own database is evidence to the operator and to
  nobody else; #151 and #168 carry the external anchor.
- **The transcript/audio asymmetry.** Section 4. Recorded, not closed.

## 8. Second pass: seal everything a seal costs nothing

The first pass above answered "should content be encrypted?" with a threat
model, and the threat model said an operator-held key protects a stolen dump
and nothing else. That is still true, and nothing below claims otherwise. But
it answered a question nobody had to ask as one question, when it is two:

1. **Should content stop being server-readable?** That needs an account-held
   key, it ends search and rendering, and key loss becomes permanent. Section 4
   still stands, and nobody has asked for it.
2. **Should content that nothing reads still rest readable in a stolen dump?**
   No. A seal that costs no feature is worth having even when it only defends
   against theft, and "it does not defend against the operator" is an argument
   for not *claiming* more, not for leaving plaintext on disk.

The first pass collapsed the two and answered only the first. The owner's
decision is the second: **encrypt as much as we can.** What follows is what
that turned out to mean.

### 8.1 The test that decides each column

A column is sealed when nothing reads it except whole. A column stays plaintext
when a query reads it in a way a seal would end — and the query is named, so
the reason is checkable rather than asserted.

That is the entire test. It is not about how sensitive the words are; it is
about whether encryption costs a working feature. `INVARIANTS.md` preamble is
the reason it is written this way: a gap left open needs a reason a reader can
falsify.

### 8.2 The inventory, from `information_schema`

Every `text`, `varchar`, and `bytea` column whose name carries content-shaped
vocabulary — `body`, `content`, `text`, `transcript`, `message`, `prompt`,
`summary`, `description`, `note`, `payload`, `data` — was listed from the
catalog rather than from memory. Of 972 text-shaped columns, 38 matched, and
most of those are digests, enum-ish kinds, or public metadata. The private
content columns, and what happened to each:

**Sealed under `OpenAgents.ContentVault`:**

| Column | Readers | Why a seal costs nothing |
| --- | --- | --- |
| `voice_transcript_items.content` | one: `OpenAgents.Timeline`, whole then truncated | no index, no predicate, no export path |
| `voice_sessions.compaction_summary` | none — written, held in process state, purged | never read back from PostgreSQL at all |
| `preference_observations.summary` | none — hashed into `evidence_digest` at write | the digest commits to the words; the column is not read |
| `project_notes.body` | REST JSON and the project page, whole | no predicate, no index; rendering decrypts |

**Left plaintext, with the query that keeps it there:**

| Column | What reads it |
| --- | --- |
| `messages.content` | a `search_vector` PostgreSQL *generates* from this column, indexed `USING GIN`, driving `OpenAgents.Memory.LexicalRecall`. Sealing it ends lexical recall over your own history. This is the one the owner named, and it is the one that cannot move. |
| `issues.body` | `OpenAgents.Issues.search/2` and `OpenAgents.Issues.TaskReferences`, both `ILIKE` |
| `comments.body` | `OpenAgents.Issues.TaskReferences`, `ILIKE` |
| `forum_posts.body_text` | `OpenAgents.Forum.search/2`, `ILIKE` |
| `account_chat_runs.user_content` | nothing searches it — but the same words rest verbatim in `account_chat_events.payload`, which the replay path reads structurally. Sealing the text column alone moves the plaintext eight inches sideways. |
| `account_chat_runs.assistant_content` | the same, plus the `completion` map beside it |

**Not private content**, so out of scope rather than left: digests
(`content_digest`, `payload_digest`), enum-ish kinds (`content_kind`,
`transcript_kind`, `data_type`), token counters, public repository and project
descriptions, published changelog and incident summaries, and
`verified_artifact_listings.owner_description`, which is marketplace copy the
listing exists to publish.

`account_chat_runs` is the honest disappointment here. It is real private
conversation, nothing searches it, and it is still plaintext — because the
duplicate beside it is jsonb the streaming replay path reads by key, and
sealing that is its own change with its own decisions about what stays
structured. `plaintext_private_columns/0` carries that reason, so it is a
tracked gap rather than a silence.

### 8.3 One vault, four columns, its own key

`OpenAgents.ContentVault` is the fourth vault. AES-256-GCM, versioned framing,
and additional authenticated data naming the column and the row, so ciphertext
lifted out of one row does not open as another's sentence.

It is one vault over four columns rather than four vaults. `VAULT-001`'s
property is that no vault reads another vault's key, and that holds: this vault
reads `:content_encryption_key` and nothing else, with no bridge of the kind
`config/runtime.exs` still offers the pairing vault — the bridge #192 found and
#253 repeated. What one-vault-per-column would buy is a finer rotation blast
radius, at the price of one production secret per column, for columns that are
all readable to the same operator through the same application. The cost is
recorded instead: rotating this key strands all four columns together.

The key is **required**, not optional. Without it a transcript, a summary, an
observation, and a note each refuse to be written rather than being written
readable, so `RuntimeConfig.validate/1` refuses a staging or production boot
without it. `cloak_ecto` is still rejected, for the reason section 5 gives.

### 8.4 Expand and contract, because the fleet rolls

Each column got a sibling `*_ciphertext` column, a backfill that seals every
existing row and nulls the plaintext, and a `_present` check constraint so "this
row has text" stays true while both halves are live. The plaintext columns are
still declared and still read as a fallback, because `RELEASE-006`'s rolling
replacement leaves nodes on the previous release writing into them. They are
dropped by a contract migration a release later, the way
`machine_pairings.user_id` was.

Two limits, recorded rather than implied:

- **Dead tuples.** `UPDATE ... SET content = NULL` writes a new row version and
  leaves the old one on disk until autovacuum reclaims it. The plaintext
  survives in dead tuples for a bounded window after the backfill.
- **The roll window.** A node still running the previous release writes
  plaintext for as long as the replacement takes. Those rows are readable until
  the contract migration, which is why the fallback reader exists.

### 8.5 What the status page says now

`encrypted_at_rest` is still `false`, and sealing four columns did not move it.
That is the design working. The boolean is `true` only when *no* private column
rests as plaintext, and `operator_reads_source` is its negation, so this change
cannot be mistaken for protection from the operator. `EXIT-006` exists to keep
that claim off the page, and it still does.

### 8.6 Proof

`test/openagents/forge/at_rest_test.exs` gained a `describe` block that, for
each sealed column, writes through the application path a person reaches and
then asks PostgreSQL two questions with raw SQL: is the ciphertext column free
of the words, and is the plaintext column it replaced empty. The second is the
one a round-trip test cannot ask — a schema that seals on write and opens on
read passes a round trip whether or not anything reached disk.

`test/openagents/forge/key_rotation_test.exs` adds the two questions #253 is
about: another vault's rotation must not reach sealed content, and this vault's
own rotation must strand it rather than falling back to a keyring it does not
have.

The population still comes from `information_schema`. `content_ciphertext`,
`summary_ciphertext`, `compaction_summary_ciphertext`, and `body_ciphertext`
all match the secret-shaped pattern on `cipher`, so each had to be classified
before the proof would go green — the same mechanism that catches a plaintext
token column now catches an unclassified ciphertext one.
