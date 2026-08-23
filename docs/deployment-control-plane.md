# Deployment control plane

How a deployment intent becomes an executed run, and what stops it.

This plane serves tenants: a repository deploys its own code to its own
environments. It is not the forge fleet-promotion surface. Promoting the
OpenAgents release itself remains operator-only behind `deployments:promote`,
and nothing described here can reach it.

## The contract

A deployment request states an intent. It never states authority. The control
plane derives every authority decision from durable records: repository
membership, the environment's protection policy, published check results bound
to exact bytes, and recorded approvals. A caller cannot widen its own
authority by asserting a field.

Four rules hold everywhere in this plane:

1. **Identity is exact.** A request names a full 40-character commit SHA and a
   `sha256:`-prefixed artifact digest. A branch or tag is recorded as
   provenance, never resolved later.
2. **Admission precedes execution.** A provider receives an immutable
   execution object built after policy admitted the run. It never receives
   caller credentials, and it resolves secrets only for its own bound
   environment.
3. **Uncertainty is not success.** A provider failure, exception, exit,
   timeout, or unknown result terminalizes the run as failed. Only an explicit
   provider success produces a success receipt.
4. **History is append-only.** Every state change writes a sequenced
   deployment event with a redacted, bounded payload.

## Objects

| Object | What it holds |
| --- | --- |
| Environment | The provider binding, secret *references*, and the protection policy for one target such as `preview` or `production`. |
| Request | The intent: commit SHA, artifact digest, source provenance, creator principal, idempotency key, and input digest. |
| Run | The execution of one admitted request: state, lease, attempt count, provider receipt. |
| Check result | A trusted workflow's verdict, bound to an exact commit SHA and artifact digest. |
| Approval | One principal's decision on one request, with a reason. |
| Workflow grant | A short-lived, single-context credential issued to a workflow. |
| Event | Append-only evidence of one transition. |

An environment stores the *name* of a secret, never its value, so no read path
can disclose one.

## States

```text
requested ─▶ checking ─▶ waiting_for_approval ─▶ queued ─▶ deploying ─▶ succeeded
                                                                    └─▶ failed
     └────────────────────── cancelled / superseded ──────────────────────┘
```

`OpenAgents.Deployments.Lifecycle` is the only place that defines legal
transitions, and `OpenAgents.Deployments.transition/4` enforces them inside a
transaction against the durable row. Terminal states have no successors, a run
cannot skip `deploying` to reach `succeeded`, and a run that is already
`deploying` cannot be superseded.

## Principals

`OpenAgents.Deployments.Principal` distinguishes a human, a workflow, an
approver, a provider, and a platform operator. The differences are
enforcement, not labels:

- A human request requires writable repository membership, rechecked at
  sensitive transitions rather than only at creation.
- A workflow request requires a grant whose repository, environment, source
  ref, source workflow, and workflow run ID all match the request. A grant
  binds to one context and cannot widen it.
- A workflow principal cannot approve, and a requester cannot approve its own
  request when the policy requires separation of duties.
- Operator recovery authority (lease reconciliation) is separate from tenant
  deployment authority.

Cross-repository reads, approvals, cancellations, and provider bindings are
denied. A public repository is readable by visibility; a private repository
requires membership.

## Policy

`OpenAgents.Deployments.Policy` evaluates one environment's protection
document against one request and returns `:satisfied`, `:pending`, or
`:blocked` with a durable explanation for every rule it evaluated. The rules
are allowed branches, allowed tags, allowed source workflows, freeze, the
deployment window, artifact age, required checks, and required approvals.

Required checks match exact bytes. A check published for the same commit but a
different artifact digest, or a check older than the environment's validity
limit, does not satisfy a requirement — which is what prevents replaying a
stale green build onto different bytes. A missing required check leaves the run
pending rather than admitting it.

Per-environment concurrency is `queue`, `cancel`, `reject`, or `supersede`. A
preview environment can supersede an in-flight request; production never
supersedes implicitly.

## Execution

`OpenAgents.Deployments.Worker` claims a queued run under a lease, renews it
while deploying, and reconciles runs whose lease expired after a crash. Before
handing work to the provider it rebuilds the execution object and re-evaluates
policy, so a revoked membership or a freeze declared after queueing stops the
run. Cancellation requested during provider execution is observed before the
run terminalizes.

Provider idempotency is keyed by run ID, so a retried attempt cannot deploy
twice. `OpenAgents.Deployments.Providers.Fake` implements the provider
contract for tests and for the contract-first phase, before real
infrastructure exists.

The worker starts only when `DEPLOYMENT_CONTROL_PLANE` is enabled, validated
by `OpenAgents.RuntimeConfig`. The API surface does not depend on that flag: a
host that cannot execute runs still records and evaluates them.

## API

The routes live under `/api/v3/repos/:owner/:repo` and require
`deployments:write` or a workflow grant. `forge:write` is not deployment
authority.

| Route | Purpose |
| --- | --- |
| `GET deployment-environments` | List environments. |
| `PUT deployment-environments/:name` | Create or update an environment and its policy. |
| `GET deployment-environments/:name/protection` | Read protection requirements. |
| `POST deployments` | Request a deployment. |
| `GET deployments` | List runs, bounded and paginated. |
| `GET deployments/:id` | Read one run. |
| `POST deployments/:id/cancel` | Cancel, optionally under a state precondition. |
| `POST deployments/:id/approvals` | Approve or reject. |
| `GET deployments/:id/approvals` | List decisions. |
| `GET deployments/:id/events` | Poll append-only events. |
| `POST deployment-checks` | Publish a trusted check result. |
| `POST deployment-workflow-grants` | Issue a workflow grant. |
| `DELETE deployment-workflow-grants/:id` | Revoke a workflow grant. |

Errors use one stable JSON shape with a typed code. Writes accept an
idempotency key: replaying the same key and the same input digest returns the
original run, and reusing the key with different bytes is a conflict.

## Related contracts

- `INVARIANTS.md`, `DEPLOYPLANE-001` through `DEPLOYPLANE-005`.
- `docs/taxonomy.md` for the difference between this plane and forge promotion.
