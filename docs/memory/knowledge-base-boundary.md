# The knowledge-base boundary

The knowledge base and system memory both put network-level knowledge in front
of every session. This page records the line between them, where that line is
enforced, why it is enforced there rather than at recall, and how to run a
promotion.

Contract: `docs/memory/2026-08-25-system-memory-spec.md` section 8 in
`OpenAgentsInc/openagents`. Invariant: `INVARIANTS.md`, MEMORY-012.

## The line

The knowledge base owns what the project has reviewed and decided. Memory owns
what the network has observed and can evidence. A stance is editorial; a memory
row is evidentiary.

| | Knowledge base | System memory |
| --- | --- | --- |
| Unit | Stance or doc summary | Memory row |
| Authority | Human review; content checked into git | Evidence refs; steward admission receipt |
| Change | Regenerated from docs; edited like content | Superseded by later rows; never edited |
| Provenance | Source doc and review date | Writing account, `as_of`, evidence refs |
| Dispute | Documentation change | Challenge and refutation records |
| Note label | `[From the OpenAgents knowledge base — …]` | `[From memory: system, …]` |

The knowledge base lives in `OpenAgentsInc/openagents`: the corpus of stances is
`plugins/knowledge-base/kb/stances.json`, compiled by `build-kb.mjs` into
`kb.json` and embedded in a WebAssembly plugin the CLI loads. System memory
lives here, in the `system` bucket of `OpenAgents.Memories`.

## Where the boundary is enforced

**At promotion, in `OpenAgents.Memories.Promotions`.** Not at recall.

The two rails no longer meet in one process. The client retrieves the knowledge
base and concatenates its note into the outgoing turn text; this server recalls
memory inside `POST /api/v1/responses` and appends its note below the caller's
`instructions`. Both reach the model, neither sees the other.

The specification's second rule — the knowledge base wins a recall collision —
therefore needs an enforcement point chosen deliberately. This is the choice and
the reasoning.

### The collision test

**A memory and a stance are the same claim exactly when a promotion tombstone on
that memory names that stance.** Nothing else is a collision.

That is decidable, it is recorded by a person who checked, and it is the only
identity the two rails can share. The corpus gives each stance a stable
kebab-case `id` (`earning-bitcoin`, `coder-tiers`); a promotion writes that id
into the `stance` column of a tombstone. Two claims that merely share
vocabulary are two claims. A memory that quotes a stance id in its prose — a
claim *about* the corpus, say — is a different claim and keeps its place in
recall.

### Why not enforce at recall

Both recall-time shapes the specification names need the client to say "my
knowledge-base hit covers this memory", and neither can say it.

* **The identifier does not survive.** The corpus has stance ids, but the
  plugin's `Entry::Stance` does not deserialize `id`, so it is absent from the
  hit, from the plugin's declared output schema, from the TypeScript
  `KnowledgeHit`, and from the injected note. A client-side rule would compare a
  stance's prose to a memory's prose, and a server-side rule would compare
  prose the client forwarded. Either is a similarity heuristic.

* **A heuristic shipped as a rule is worse than no rule.** "The knowledge base
  wins collisions" reads as a guarantee. A false positive drops a true memory
  the reader never learns was withheld; a false negative lets the duplicate
  through anyway. Duplication is the benign failure — the two notes are labelled
  differently and a model can weigh them — and suppression is the destructive
  one, so a rule that trades the benign failure for the destructive one is a bad
  trade even when it is usually right.

* **Sending the hit to the server also widens the request.** A client-supplied
  "the knowledge base covers this" field is an untrusted claim that mutes the
  memory rail, and the server would depend on corpus state it cannot check.

* **The rule's purpose is served by draining.** When a stance and a memory
  really do speak to one claim, the correct response is not to silence one every
  turn: it is to promote, so the claim has one home. That is the specification's
  first rule, and making it operable is what this page and
  `Promotions.promote/3` are for.

Given the collision test above, a recall-time rule would also have nothing left
to do. A promoted claim is superseded, so it is not live; its tombstone can never
be admitted, so it is not eligible. Recall surfaces live admitted rows
(specification 7.1), so the promoted claim's one live home is the stance, and
there is no second speaker to silence.

### What is deliberately not enforced

* **An unlinked coincidence.** A stance and an admitted memory that a reader
  would call one claim, with no promotion between them, both attach. Nothing
  decides that today, for the reasons above. If it becomes a real problem, the
  fix is to promote the memory, not to add a threshold.

* **A fresh claim written on a promoted slug.** After a promotion the slug's live
  head is a tombstone; a steward who admits a new row on that slug is re-opening
  a claim the project already drained. Refusing it would take a read of
  `memories` by slug across accounts, which is the predicate MEMORY-010 exists to
  keep out of this store.

Both are named in MEMORY-012 so that nobody reads the invariant as covering
them.

## What a promotion writes

`Promotions.promote/3` is the ordinary correction path with a fixed shape. It
writes a superseding row on the claim's slug — a **promotion tombstone** — and
points the old row at it.

The tombstone carries:

* `stance` — the knowledge-base stance id. Lowercase words joined by hyphens.
* a body this server composes, naming that stance. The table requires the stance
  to appear in the body (`position(stance in body) > 0` in
  `memories_system_shape`), so a tombstone that points nowhere cannot exist.
* `evidence_refs` — where the stance lives and the digest of what was reviewed.
* `admission: "candidate"`, which is all it can ever hold. No admission,
  challenge, or refutation may name a promotion tombstone: the composite foreign
  key `(memory_id, memory_promoted) -> memories (id, promoted)` refuses it, with
  the literal `false` pinned by `memory_admissions_shape`.

Nothing is deleted. The claim, its evidence, and its admission record stay
readable underneath the tombstone, and a promotion by a steward resolves the
claim's open challenges in the same transaction, as any steward correction does.

## Running a promotion

A promotion has two halves, and they land in two repositories. Do the review
half first: until the stance exists, the tombstone would point at nothing.

### 1. Add the stance to the corpus

In `OpenAgentsInc/openagents`:

1. Add a record to `plugins/knowledge-base/kb/stances.json` with an `id`
   (lowercase words joined by hyphens), a `title`, the `questions` a reader
   would ask, a `state`, the `answer`, the `sources` it rests on, and today's
   `date`. Cite the memory you are draining among the sources.
2. Rebuild the corpus and the artifact:

   ```sh
   cd plugins/knowledge-base
   node build-kb.mjs
   cargo build --release --target wasm32-unknown-unknown -p knowledge-base
   ```

3. Re-pin `artifact.digest` in `plugins/knowledge-base/manifest.json` to the
   digest of the rebuilt `knowledge_base.wasm`.
4. Review and land the change the way any documentation change lands. The
   stance is only reviewed once a person has reviewed it.

### 2. Drain the memory

In this repository, as a steward:

```elixir
OpenAgents.Memories.Promotions.promote(steward, memory_id, %{
  "stance" => "gateway-402-retired-model",
  "slug" => "sys:gateway-402-retired-model",
  "evidence_refs" => [
    %{
      "kind" => "url",
      "ref" => "https://openagents.com/OpenAgentsInc/openagents/plugins/knowledge-base/kb/stances.json",
      "digest" => "sha256:…"
    }
  ]
})
```

* `slug` is the target's slug. It binds the tombstone to the claim it drains,
  the same way `Admissions.supersede/3` requires it. Read it off the claim
  before promoting.
* `digest` is the digest of the reviewed stance, so the evidence behind the
  promotion cannot be swapped afterwards.
* `as_of` defaults to today — the date the claim became a reviewed position.

Refusals: `:steward_required` when the account is not an operator,
`:stance_required` when no stance is named, `:not_supersedable` when the target
is not a live system memory, and a changeset for a malformed stance id or
missing evidence.

There is no HTTP route for this, exactly as there is none for admission or
challenge. Promotion is a steward's action on the network's store, taken from a
console with the same authority `OpenAgents.Memories.Admissions` requires.

### 3. Check the drain

The claim should have left recall without leaving the store:

```elixir
claim = OpenAgents.Repo.get!(OpenAgents.Memories.Memory, memory_id)
claim.superseded_by_id                         # the tombstone
OpenAgents.Memories.Admissions.status(claim)   # still "admitted" — nothing was erased
```

## When to promote

A system memory is ready to drain when it has stabilized: admitted, unchallenged
for a sustained period, and repeatedly recalled. Promoting earlier turns an
observation into a reviewed position before the review has anything to review.

Promote sooner than that in one case: when a stance already covers the claim.
That is the duplicate the recall-time rule was written for, and draining it is
how this store answers it.
