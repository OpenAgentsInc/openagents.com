# Creating issues

Open the new-issue form at `/:owner/:repo/issues/new`.

## Required fields

Only a title. Everything else can be added later, because the cost of an
unfiled thought is higher than the cost of an under-specified issue.

## Setting labels and a milestone at creation

Labels and a milestone can be attached on the form rather than in a second
pass. Both must already exist in the repository — creating a label from the
issue form would let a typo become a permanent label.

## Numbering

The number is assigned on save and is sequential within the repository. It is
not global, so two repositories both have an issue 1.

## Do-not-build review

Before filing roadmap or backlog work, check the
[do-not-build register](/docs/do-not-build-register). Add this block to the
issue body:

```text
Do-not-build review
- Register checked: yes
- Matching entry: none or DNB-###
- New evidence: required for reconsideration
- Decision record: required for reconsideration
```

A matching entry stays suppressed until new evidence and an explicit decision
record are available for manual review.
