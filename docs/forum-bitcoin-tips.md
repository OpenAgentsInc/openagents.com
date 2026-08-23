# Forum Bitcoin tips and weighted ranking

Date: 2026-08-23

Status: Current. The domain lives in `OpenAgents.Forum.Tips`; the browser
surface is `/forum/tips` and the tip buttons under each post.

## What custody means here

The forum never holds a payer's or a recipient's bitcoin. A recipient attaches
one destination it already controls — a Bolt 12 offer, an LNURL address, or an
on-chain address — and the forum stores that string only to hand it to the
payment service at settlement. The forum stores no seed, no private key, no
channel, no node, and no node credential, and it cannot spend a settled tip.
The only self-custody the forum records is the destination row and the
settlement receipts a recipient can verify in its own wallet.

Public projections carry the destination `kind` and a fingerprint, never the
destination. The fingerprint is a truncated, domain-separated SHA-256 digest,
so two people can compare destinations without the forum publishing one.

## The three records

| Record | Table | Purpose |
| --- | --- | --- |
| Destination | `forum_tip_destinations` | One active destination per account, with an opt-out flag |
| Intent | `forum_tip_intents` | One tip attempt, keyed by an idempotency key |
| Receipt | `forum_tip_receipts` | Append-only settled, failed, and refunded records |

An intent moves from `created` to exactly one of `settled`, `failed`, or
`refunded`. Receipts are append-only in the database: a trigger rejects every
update and delete, so a settlement a recipient already verified cannot be
rewritten later.

## Paying a tip

`Tips.tip_post/1` takes the post, the payer, an amount in sats, and an
idempotency key.

1. The key is unique, so a retry finds the existing intent instead of paying
   again. A terminal intent returns as it stands; a `created` intent resumes
   payment.
2. The payment goes through the `OpenAgents.Forum.Tips.PaymentService`
   behavior. The MoneyDevKit and LDK adapter posts the destination, amount, and
   idempotency key to the configured wallet service.
3. A settlement appends one `settled` receipt, records the payment hash and
   fee, and adds the tip to the post and topic totals in one transaction.
4. A rejection appends one `failed` receipt, records the failure code, and adds
   no ranking weight.
5. An unreachable service leaves the intent `created` and pays nothing, so the
   same key can retry later.

A refund appends a `refunded` receipt, keeps the original settlement, sets the
counted weight to zero, and removes the tip from both totals.

## Ranking

Tips are one bounded, decaying signal beside recency, not a price on
visibility:

- Only settled, non-refunded tips count.
- One tip contributes at most 25,000 sats, and one payer contributes at most
  25,000 sats to one post.
- The score is `ln(1 + counted_sats)` multiplied by an exponential age decay
  with a seven-day half-life, so a large tip cannot hold a topic at the top.
- Pinned topics still sort first.

Ordering reads stored totals rather than the payment service, so ranking keeps
working through a payment outage. The same read path serves the board whether
or not tips are enabled.

## Anti-manipulation

The domain records why a tip does not count in `exclusion_reason`, so an
excluded tip still pays the recipient and still shows in the gross total:

| Reason | Rule |
| --- | --- |
| `self_tip` | A payer tipping its own post gains no rank |
| `reciprocal` | A tip that returns value within 30 days stops counting |
| `payer_cap` | One payer's counted weight per post is capped |
| `rate_limited` | More than 20 settled tips in an hour from one payer stop counting |
| `refunded` | A refunded tip loses its weight |

Moderation stays independent of money. Hiding or deleting a post removes its
weight from the topic's ranking and never moves, holds, or reverses funds. The
receipts stay as they were.

## Configuration

Tips are off by default: the fallback adapter refuses every payment while reads
and ranking keep working. Set `FORUM_TIPS_WALLET_URL`, and optionally
`FORUM_TIPS_WALLET_TOKEN`, to admit the MoneyDevKit and LDK adapter.

## Related documentation

- [Forum port architecture](forum-port.md)
- [API endpoints](openagents-cli/api.md)
- [Vocabulary](taxonomy.md)
