# Product promises registry

The product promises registry records what OpenAgents claims, what has shipped,
and what still needs a gate. The registry is a Projects V2 project with exactly
one `promise_state` field whose values are `LIVE`, `GATED`, and `WITHDRAWN`.

## States and gates

- `LIVE` requires a readable `accepted_outcome` evidence entry that names an
  existing `OpenAgents.Compensation.OutcomeDecision` whose `decision` is
  `accepted`. Issue, changelog, and forge receipt entries remain supporting
  evidence, but they cannot satisfy the gate, and neither can a link.
- `GATED` requires `gate.missing`, `gate.owner`, and `gate.next_review`.
  A gated promise with a missing gate is a bounty candidate.
- `WITHDRAWN` requires `withdrawal.reason`, `withdrawal.replacement`, and
  `withdrawal.date`. Withdrawn promises remain visible.

The server sets `verified_at` when a promise enters or is reverified as
`LIVE`. The client cannot set this value.

See [the accepted-outcome contract](accepted-outcome-contract.md) for how an
agent-authored completion claim earns an accepted outcome receipt.

## Record shape

Store the record in `values["promise"]` and store its state under the name of
the `promise_state` field:

```json
{
  "Promise state": "GATED",
  "promise": {
    "id": "forge_bounty_clearing_loop_v1",
    "problem": "Verified work does not have a complete settlement loop.",
    "claim": "A forge issue can move from claim to settlement.",
    "scope": "One public bounty issue and its receipts.",
    "acceptance_criteria": ["A claim and settlement are linked."],
    "success_metrics": ["One bounty completes end to end."],
    "owner": "OpenAgents",
    "target": "2026-10-31",
    "evidence": [
      {
        "kind": "accepted_outcome",
        "decision_receipt_ref": "outcome-decision:example"
      }
    ],
    "gate": {
      "missing": "A verified settlement receipt.",
      "owner": "OpenAgents",
      "next_review": "2026-09-30"
    }
  }
}
```

Promise IDs use lowercase letters, digits, and underscores. They are unique
within a project. Every promise item has one canonical issue.

## API

List promises by state:

```text
GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items?promise_state=LIVE
```

List bounty candidates:

```text
GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items?bounty_candidate=true
```

Read the append-only history for an item:

```text
GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}/events?page=1
```

Promise data appears under `openagents.promise`. Evidence that points to a
repository or issue you cannot read is omitted from both the record and its
evidence count.

## Backfill the registry

1. Run `mix ecto.migrate`.
2. Review `priv/promises/curated.json`. The file contains only promises
   derived from published material in `docs/episode-triage.md`.
3. Run the task:

   ```sh
   mix openagents.promises.backfill \
     --owner OpenAgentsInc \
     --repo openagents.com \
     --project-number 1
   ```

The task creates the state field when it is missing, creates one canonical
issue per promise, and skips existing promise IDs. If evidence cannot satisfy a
promise's state gate, the task reports the promise and its error, skips it, and
continues. You can rerun it safely.
