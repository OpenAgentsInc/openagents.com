# Ox Alpha provider limits

Date: 2026-08-23

Status: Point-in-time measurement

This document records the Ox Alpha capacity that a router can verify without
guessing. The measurements use public model catalogs and one bounded,
unauthenticated completion request per provider. Authenticated provider keys
were not available, so the run did not attempt load testing or claim a
concurrent-request ceiling.

Provider promotions and model availability can change without notice. Recheck
the linked sources and the authenticated limit endpoints before changing a
production routing budget.

## Evidence labels

- **Measured**: A provider API returned the value or response on 2026-08-23.
- **Documented**: Current provider documentation states the value.
- **Observed**: The value was recorded from a provider surface, but the current
  public surface does not expose enough information to reproduce it.
- **Claimed**: A provider or announcement advertised the value without an API
  receipt that a router can enforce.
- **Unknown**: The provider does not publish the value, or an authenticated
  request is required.

## Limit map

| Provider | Model | Availability measurement | Context | Maximum output | RPM | TPM | Other quota | Concurrent requests | Limit scope |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| OpenRouter | `stealth/ox-alpha` | Public catalog listed the model at `$0` input and output. An unauthenticated completion returned `401`. | 1,048,576 measured | 131,072 measured | 20 documented for free models | Unknown | 50 requests/day before $10 of lifetime credit; 1,000 requests/day after $10, documented for free models | Unknown | OpenRouter documents that additional accounts or API keys do not increase its global rate limit. The exact treatment of this zero-priced slug, which does not end in `:free`, requires an authenticated response. |
| Nous Portal | `stealth/ox-alpha` | Public catalog listed the model at `$0` input and output, but an unauthenticated completion returned `400` with `Unknown model`. | 1,048,576 measured | 131,072 measured | 50 observed for the Free plan | 500,000 observed for the Free plan | No numeric daily quota verified | Unknown | Unknown. The public plan page describes account plans but does not state whether multiple keys share one quota. |
| Venice | `stealth-ox-alpha` | Public catalog listed the beta model as online at `$0` input and output. An unauthenticated completion returned `402` with `Authentication required`. | 1,048,576 measured | 131,072 measured | Unknown for Ox Alpha | Unknown for Ox Alpha | Venice documents model tiers from 20 to 500 RPM and 500,000 to 1,000,000 TPM, but does not map Ox Alpha to a tier publicly. | Unknown | The authenticated `/api_keys/rate_limits` endpoint returns limits for one key. Whether multiple keys share another account-level ceiling remains unknown. |
| OpenCode Zen | `x-preview-f-free` | Documentation listed Ox Alpha Free. An unauthenticated completion reached the gateway and returned `503` with `Endpoint is unavailable`. | Unknown | Unknown | Unknown | Unknown | OpenCode Go lists dashes for Ox Alpha's five-hour, weekly, and monthly request estimates. | Unknown | Unknown |

The OpenRouter free-model quota applies across free-model traffic rather than
reserving capacity for Ox Alpha. OpenRouter can also return an upstream
provider `429` after its own quota accepts a request.

The Nous Free plan values were recorded in issue #40 on 2026-08-22 as
50 RPM and 500,000 TPM. The current unauthenticated plan page says only
“Standard rate limits,” so treat those numbers as an observation until an
authenticated key reports matching headers or limits.

Venice publishes these default model tiers:

| Tier | RPM | TPM |
| --- | ---: | ---: |
| XS | 500 | 1,000,000 |
| S | 75 | 750,000 |
| M | 50 | 750,000 |
| L | 20 | 500,000 |

Do not assign Ox Alpha one of these budgets by model size or performance. Use
`GET /api/v1/api_keys/rate_limits` with the routing key and record the returned
model mapping.

## Routing conclusion

The current evidence does not support a multi-request concurrency budget for
any provider. A router can use these results as admission gates:

- Keep OpenRouter within the documented 20 RPM and account-level daily quota,
  but start with one in-flight request until an authenticated probe finds the
  upstream ceiling for `stealth/ox-alpha`.
- Keep the Nous lane disabled until an authenticated completion resolves the
  public-catalog and completion-endpoint mismatch.
- Admit Venice only after its key-specific limit endpoint maps Ox Alpha to an
  RPM and TPM budget.
- Keep OpenCode Zen disabled while the Ox Alpha endpoint returns `503`.

The advertised OpenCode capacity of 100 trillion tokens per day and Nous
capacity of 1 quadrillion tokens per day are claims, not routing budgets. The
Nous Free plan observation is 500,000 TPM, which can carry at most 720 million
tokens per day if the limit remains continuously available.

## Measurement procedure

Use a dedicated free-tier account and key for each provider. Do not rotate
accounts or keys to evade a provider limit.

1. Fetch the provider's key or rate-limit endpoint and save the response
   headers without the authorization header.
2. Send one completion with a fixed prompt and `max_tokens: 16`. Confirm the
   model identifier, context metadata, and rate-limit headers.
3. Run three batches at concurrency 1, 2, 4, and 8. Stop at the first `429`,
   quota error, or batch with more than 20% provider failures.
4. Do not retry failed requests during the measurement. Record
   `Retry-After`, every `X-RateLimit-*` header, the accepted concurrency, and
   the first rejected concurrency.
5. Wait for the longest reported reset window before testing the next
   provider. Keep the prompt and output bound unchanged.
6. Repeat the probe with a second key in the same account. If the remaining
   quota changes for both keys, record the limit as account-scoped. Use a
   provider-supported organization test only when its terms permit one.

Use the following catalog and limit sources:

- [OpenRouter model catalog](https://openrouter.ai/api/v1/models)
- [OpenRouter limits](https://openrouter.ai/docs/api_reference/limits)
- [Nous model catalog](https://inference-api.nousresearch.com/v1/models)
- [Nous plans](https://portal.nousresearch.com/info)
- [Venice model catalog](https://api.venice.ai/api/v1/models)
- [Venice rate limits](https://docs.venice.ai/api-reference/rate-limiting)
- [OpenCode Zen](https://opencode.ai/docs/zen/)
- [OpenCode Go limits](https://opencode.ai/docs/go/)

## Probe receipts

The bounded unauthenticated probes ran between 04:44 and 04:46 UTC on
2026-08-23:

| Provider | Endpoint | HTTP status | Result |
| --- | --- | ---: | --- |
| OpenRouter | `POST https://openrouter.ai/api/v1/chat/completions` | `401` | `No cookie auth credentials found` |
| Nous Portal | `POST https://inference-api.nousresearch.com/v1/chat/completions` | `400` | `Unknown model: stealth/ox-alpha` |
| Venice | `POST https://api.venice.ai/api/v1/chat/completions` | `402` | `Authentication required` |
| OpenCode Zen | `POST https://opencode.ai/zen/v1/chat/completions` | `503` | `Endpoint is unavailable` |

Each request used the provider-specific model identifier, one user message
that requested `OK`, and an eight-token output bound. The run sent no
concurrent traffic.
