# Which columns stop being server-readable, and what that would cost

**Date:** 2026-08-25
**Issue:** #193
**Parent:** #94
**Companion:** `docs/2026-08-24-private-export-encryption.md`

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
sealed.** Rejected, and it was the closest call. The asymmetry is real, but the
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

- **Content columns are plaintext, and the operator reads them.** That is the
  decision, not a gap in it. #193 stays open because the acceptance criteria
  say it does: encryption did not land, and `/status` keeps publishing `false`.
- **No operator read is audited.** `ADMIN-001`. An access log the operator
  writes into the operator's own database is evidence to the operator and to
  nobody else; #151 and #168 carry the external anchor.
- **The transcript/audio asymmetry.** Section 4. Recorded, not closed.
