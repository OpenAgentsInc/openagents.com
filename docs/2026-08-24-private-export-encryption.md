# Encrypting a private export to a key the operator does not hold

**Date:** 2026-08-24
**Issue:** #178
**Parent:** #94
**Companion:** `docs/forge-operator-independence.md`

#94 asks that private repository exports stay encrypted and access controlled.
Access control held. Encryption did not, and `docs/forge-operator-independence.md`
recorded that rather than claiming it. This document is the decision that
replaces the placeholder.

## 1. The decision

**The account export encrypts to an `age` recipient the account supplies, and
the storage layer behind it stays plaintext. Both facts are published
together.**

```sh
age-keygen -o key.txt
age-keygen -y key.txt          # age1…
```

Give the `age1…` value to `GET /data/export/account?recipient=age1…`, or paste
it into the field beside the export button on `/memory`. The response is an
[age v1](https://age-encryption.org/v1) document. Open it with any
implementation of that specification:

```sh
age --decrypt -i key.txt openagents-account-data.json.age > export.json
```

Omitting `recipient` returns today's plain JSON, because an export nobody can
open is not portability either. Supplying a recipient that is not an `age`
public key returns `422` rather than falling back to plaintext: a request that
asked for encryption never silently receives an unencrypted document.

## 2. What this protects, exactly

The threat model matters more than the mechanism, because the two obvious
designs protect against different adversaries and only one of them is worth
naming.

**Encrypting to a key the operator holds** — the shape of the three existing
vaults, which take their keys from the operator's environment — protects
against a stolen database dump, a stolen backup, and a stolen bucket. It
protects against nothing else. The operator decrypts at will, because the
operator has the key.

**Encrypting to a key only the account holds** protects against the operator,
for the artifact it covers. The private half of an `age` identity is generated
on the account's machine and never reaches this forge.

What that buys here is bounded and the bound is the substance:

- **Protected:** the exported document after it leaves the application
  boundary. Its copies, whatever the response passes through in transit, any
  proxy or access log that captures a body, any backup of a downloaded file,
  and any later re-reading of that file by anyone who obtains it, the operator
  included.
- **Not protected:** the contents. The forge builds the export by reading
  plaintext PostgreSQL. The operator held every record before this ran and
  holds them still. Nothing in this decision makes an operator read of the
  source auditable, and `ADMIN-001` records that no operator read is audited.

So this is encryption of an artifact, not confidentiality of a store. Saying
otherwise would be exactly the narrowing #178's contract forbids: "Do not
narrow the claim to the export path while the storage layer stays plaintext.
Either both are stated, or neither is claimed." Both are stated —
`GET /api/status` publishes `independence.private_data.export_recipient_encryption`
as `true` and, beside it, `encrypted_at_rest` as `false` and
`operator_reads_source` as `true`, the last derived from the second so the
pair cannot drift apart.

## 3. Why key loss decides this

The usual objection to recipient-held keys is that the account loses its data
when it loses the key. That objection is decisive for storage and does not
apply to an export at all, and noticing the difference is what made this
decidable.

**An export is derived.** An account that loses its `age` identity generates
another one and requests the export again. Nothing is lost, because the export
was never the record — PostgreSQL is, and it is unchanged. The cost of key
loss on this path is one repeated download.

**Storage is not derived.** A key only the account holds, applied to columns,
makes key loss permanent data loss and makes every server-side read
impossible: the issue list, search, rendering, and the per-repository
projections `TRANSPARENCY-001` publishes all read those columns on the server.

That asymmetry is the whole reason recipient-held encryption is right on one
side of the boundary and wrong on the other, and it is why the storage half is
a separate decision under #193 rather than an unfinished part of this one.

## 4. Options rejected

**Encrypt the export under an operator-held key.** Rejected. It protects a
stolen backup, which the disk and bucket already do, and publishing it would
read as protection from the operator while providing none. It is the claim
`EXIT-006` exists to keep off the status page.

**Encrypt every column at rest under an operator-held key.** Rejected for this
issue, for the same reason, and separately because it is a large change that
buys the threat model nothing it does not already have. `#193` carries the
at-rest question with the real trade written down.

**Encrypt every column at rest under an account-held key.** Rejected. Key loss
becomes permanent data loss, and every server-side read of that column stops
working — which is most of the product. A serious version of this decides
*which* columns stop being server-readable and what the account gives up, and
that is a product decision rather than a cryptography one. `#193`.

**A bespoke sealed-box format with an OpenAgents decryptor.** Rejected, and
this is the rejection that matters most. An export a recipient can only open
with software the operator wrote leaves the operator defining the terms on
which you read your own data. The point of the exercise is independence, so
the format has to be one the recipient can read with a tool nobody here
controls. `age` has multiple independent implementations and a published
specification.

**PGP/GnuPG.** Rejected on the same axis it wins on. It is more widely
installed, and its key model, subkey handling, and armour formats are a large
surface to get right in a hand-rolled encoder. `age` is one recipient stanza,
one AEAD, and one stream construction — small enough to implement correctly
against the specification and check against the reference implementation,
which is what `test/openagents/data_rights/age_test.exs` does.

**Encrypt the two `DATA-004` conversation exports too.** Not rejected, not
done. `GET /data/export`, `GET /data/export/atif`, and `GET /memory/export`
take the same shape and would take the same parameter. `#178` asked about the
account export, and widening the surface in the same change would have widened
what needs proving. It is a small follow-on rather than a gap in the decision.

## 5. What was proven, and how

`test/openagents/data_rights/age_test.exs` and the route tests in
`test/openagents/data_rights/account_export_test.exs`.

The claim is not "the bytes round trip" — two of our own implementations
agreeing would show nothing. It is that the recipient reads the document
**without the operator's software**, so three assertions carry it:

1. The real `age` binary decrypts what `OpenAgents.DataRights.Age` produces.
   This ran with `age` v1.3.1 when this decision landed, over a single chunk,
   over 8.1 MB spanning 124 `STREAM` chunks, and over an empty document.
2. An independent decryptor in `test/support/age_document.ex`, written from
   the specification and sharing no code with the module under test, decrypts
   it too, so the property is checked where `age` is not installed.
3. That decryptor reads `test/fixtures/age/reference.age`, a document the real
   `age` binary produced, which pins our reading of the format to the
   reference implementation and is what makes assertion 2 mean anything.

Each proof was mutation-checked: the header MAC's HKDF label was corrupted
(`age` refused the document, exit 1), the final-chunk flag was pinned to zero
(`age` refused it again), the file key was made constant, the route was made
to ignore the recipient, and the route was made to fall back to plaintext on
an invalid recipient. Every mutation was confirmed red on the named assertion
and reverted.

The constant-file-key mutation **did not bite at first**, and the gap it
exposed is worth recording rather than quietly closing. The original assertion
compared two documents and found them different — but the ephemeral X25519 key
is fresh per call, so two documents differ byte for byte even when every file
key is identical, and a recovered file key would then open every export ever
issued. The assertion now reads the file key back out of each document and
compares those. The mutation bites.

## 6. What is still open

- **The store is plaintext.** `#193`.
- **No operator read is audited.** `ADMIN-001` records it as a decision: an
  access log the operator writes into the operator's own database is evidence
  to the operator and to nobody else. Making it accountable needs the external
  anchor `#151` and `#168` carry.
- **The conversation exports are not encrypted.** Section 4.
