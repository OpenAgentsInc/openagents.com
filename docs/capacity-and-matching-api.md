# Capacity and matching API

**Status:** Contract  
**Tracking issue:** [#76, Publish quantity-based capacity and device-to-job matching APIs](https://openagents.com/OpenAgentsInc/openagents.com/issues/76)  
**Source:** [Cloud computer scale architecture audit](2026-08-22-cloud-computer-scale-architecture-audit.md)

Capacity answers a quantity question, not a presence question. A caller must be
able to tell 30 logical computers with four active leases apart from a fleet
that can admit 30 more, and it must be able to ask whether one typed job fits
before it spends a budget. These endpoints publish those numbers and that
decision.

`OpenAgents.Capacity` is a projection, not an authority. Managed runtime
capacity comes from the capacity and quota broker in the private control plane,
and connected-computer capacity comes from the `machines` and `work_jobs`
records this application already owns. Neither number is recomputed here, and
this module never admits, reserves, or leases anything.

## Endpoints

| Endpoint | Principal | Purpose |
| --- | --- | --- |
| `GET /api/capacity` | Signed-in account session | The projection the web surface reads |
| `GET /api/v3/capacity` | `chat:account` bearer token | The same projection for agents |
| `POST /api/v3/capacity/matches` | `chat:account` bearer token | Ranked candidates or a typed refusal for one job requirement |

Both capacity projections come from one function, so a web reader and an API
reader with the same authority see the same numbers.

## Runtime classes

A class is a product profile. Provider names, project identifiers, regions,
zones, clusters, hosts, guest addresses, credentials, and image paths never
appear in a response.

| Class | Isolation | Data location | Notes |
| --- | --- | --- | --- |
| `standard` | `managed_standard` | `openagents_managed` | Pooled managed runtime for ordinary work |
| `strong` | `managed_strong` | `openagents_managed` | Stronger isolation for arbitrary native code |
| `batch` | `managed_standard` | `openagents_managed` | One-shot work with no retained interactive runtime |
| `connected` | `customer_controlled` | `customer_premises` | A computer the caller connected. Always an explicit target |

A `managed_strong` requirement admits only `strong`. A `managed_standard`
requirement admits `standard`, `batch`, and `strong`. A `customer_controlled`
requirement admits only `connected`, and `connected` never appears as a
candidate for a managed requirement, so a customer's own hardware can never
become an implicit fallback.

Evidence can mark a class private. A private class is omitted from every
response instead of being reported as empty.

## Capacity projection

Schema `openagents.capacity.v1`:

```json
{
  "schema": "openagents.capacity.v1",
  "generated_at": "2026-08-23T04:00:00Z",
  "limits": {
    "reserved_headroom_fraction": 0.25,
    "active_per_conversation": 4,
    "logical_per_conversation": 30
  },
  "classes": [
    {
      "id": "standard",
      "label": "Standard",
      "isolation": "managed_standard",
      "egress": "policy_broker",
      "data_location": "openagents_managed",
      "explicit_target_only": false,
      "unit": {"vcpu": 1, "memory_gib": 2, "scratch_gib": 20},
      "quantities": {
        "logical": 30,
        "active_reservations": 4,
        "allocatable": 8,
        "queued": 2,
        "safety_headroom": 6,
        "configured_ceiling": 16,
        "observed_limit": 24
      },
      "queue": {"queued": 2, "estimated_wait_seconds": {"low": 5, "high": 90}},
      "evidence": {
        "source": "broker",
        "observed_at": "2026-08-23T03:59:48Z",
        "age_seconds": 12,
        "maximum_age_seconds": 120,
        "freshness": "fresh"
      },
      "admits": true,
      "refusal": null
    }
  ]
}
```

Quantity rules:

- `logical` counts durable records, and `active_reservations` counts current
  leases. They are separate numbers and neither implies the other.
- `allocatable` is
  `max(0, min(effective_limit - active_reservations, reported_free))`, where
  `effective_limit` is the smallest of the configured ceiling, the observed
  limit minus reserved headroom, the budget limit, and any incident or drain
  limit. `reported_free` is the free capacity the evidence reports, which
  already excludes active reservations, so the projection caps the limit-derived
  number with it instead of subtracting reservations twice. A missing
  `reported_free` leaves the limit-derived number as it is.
- `safety_headroom` reports the reserve the projection withheld, so a reader can
  see why `allocatable` is smaller than the raw observation.
- Every quantity is a non-negative integer. A missing observation renders as
  `null`, never as `0`.

Freshness rules:

- `fresh`: the observation is within `maximum_age_seconds`.
- `stale`: the observation is older. `admits` is `false`, `allocatable` is `0`,
  and `refusal` carries `evidence_stale`.
- `unavailable`: no observation exists, the broker is unconfigured, or the
  broker call failed. `admits` is `false`, quantities are `null`, and `refusal`
  carries `evidence_unavailable`.

An incident drain reports `admits: false` with the `incident_drained` refusal
code while quantities stay visible.

## Matching

`POST /api/v3/capacity/matches` takes one typed requirement:

```json
{
  "requirement": {
    "quantity": 3,
    "isolation": "managed_standard",
    "egress": "policy_broker",
    "data_location": "openagents_managed",
    "target": "openagents_managed",
    "tools": ["shell", "coding_agent"],
    "duration_seconds": 900,
    "budget": {"currency": "usd_cents", "amount": 250}
  }
}
```

`quantity` defaults to `1`, `target` defaults to `openagents_managed`, and a
`customer_computer` target requires an explicit `computer_id` the caller owns.

A match returns schema `openagents.capacity_match.v1` with ranked candidates and
the typed reason each other class was excluded:

```json
{
  "schema": "openagents.capacity_match.v1",
  "generated_at": "2026-08-23T04:00:00Z",
  "requirement": {"quantity": 3, "isolation": "managed_standard", "...": "normalized"},
  "candidates": [
    {
      "class": "standard",
      "rank": 1,
      "admissible_quantity": 3,
      "quantities": {"allocatable": 8, "queued": 2},
      "evidence": {"freshness": "fresh", "age_seconds": 12},
      "estimate": {
        "cost": {"currency": "usd_cents", "low": 12, "high": 48, "basis": "requested_quantity"},
        "completion_seconds": {"low": 120, "high": 960},
        "confidence": "medium",
        "evidence_age_seconds": 12,
        "assumptions": [
          "One unit of the class runs the whole job.",
          "Queue wait uses the current observed queue depth."
        ],
        "earnings": null,
        "earnings_reason": "no_named_buyer"
      }
    }
  ],
  "excluded": [
    {"class": "strong", "code": "quantity_unavailable", "detail": "The class admits 1 of 3 requested units."},
    {"class": "connected", "code": "explicit_target_required", "detail": "A connected computer is never an implicit target."}
  ]
}
```

Candidates rank by fresh evidence first, then by whether the class admits the
whole requested quantity, then by lower estimated cost, then by shorter
estimated completion. Ranking is routing, not authorization.

Estimates are bounds with stated assumptions and the age of the evidence behind
them. An estimate never reports earnings unless configuration names a buyer and
records a verified payout policy. Without both, `earnings` is `null` and
`earnings_reason` explains which one is missing.

## Typed refusals

A refusal returns schema `openagents.capacity_refusal.v1`:

```json
{
  "schema": "openagents.capacity_refusal.v1",
  "error": {"code": "unsupported_isolation", "detail": "No admitted class provides managed_confidential."}
}
```

| Code | Status | Meaning |
| --- | --- | --- |
| `invalid_requirement` | `422` | The body is missing, malformed, or out of bounds |
| `unsupported_isolation` | `422` | No class provides the requested isolation |
| `unsupported_egress` | `422` | No class provides the requested egress policy |
| `unsupported_data_location` | `422` | No class runs in the requested location |
| `unsupported_tool` | `422` | No class admits a requested tool category |
| `budget_below_minimum` | `422` | The budget cannot cover one unit for the requested duration |
| `explicit_target_required` | `422` | The requirement needs an explicit connected-computer target |
| `computer_not_found` | `404` | The named connected computer is not the caller's |
| `quantity_unavailable` | `409` | Every otherwise admitted class lacks the requested quantity |
| `incident_drained` | `503` | Every otherwise admitted class is drained for an incident |
| `evidence_stale` | `503` | The only otherwise admitted classes carry stale evidence |
| `evidence_unavailable` | `503` | No capacity evidence exists for any admitted class |

A refusal always names one code. A caller never receives an empty candidate list
with a `200` status.

## Redaction

The projection copies only the fields this contract names. It drops every other
field a broker reports, including provider names, project identifiers, regions
and zones, cluster and host references, guest addresses, credentials, image
paths, raw provider errors, and customer workspace content. Sensitive regions
are dropped rather than coarsened.

## Configuration

Configure the projection under `config :openagents, OpenAgents.Capacity`:

| Key | Default | Purpose |
| --- | --- | --- |
| `evidence_source` | `OpenAgents.Capacity.Broker` | The module that reads broker evidence |
| `broker_url` | `nil` | The capacity broker base URL. Unset reports `evidence_unavailable` |
| `broker_token` | `nil` | The bearer token for the broker |
| `broker_timeout_ms` | `2000` | Bounded request timeout |
| `maximum_evidence_age_seconds` | `120` | The freshness boundary |
| `reserved_headroom_fraction` | `0.25` | The reserve withheld from an observed limit |
| `class_ceilings` | `%{"standard" => 16, "strong" => 2, "batch" => 8}` | Configured safety ceilings |
| `active_per_conversation` | `4` | Active runtimes admitted for one conversation |
| `logical_per_conversation` | `30` | Logical computers admitted for one conversation |
| `unit_cost_usd_cents_per_hour` | per class | Cost bounds used by estimates |
| `buyer` | `nil` | A named buyer and its verified payout policy |

The broker stays unconfigured by default, so a deployment without the private
control plane publishes honest `evidence_unavailable` classes instead of
inventing numbers.
