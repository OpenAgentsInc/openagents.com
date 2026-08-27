# Production deployment time audit

**Date:** August 27, 2026

**Status:** Current-state audit and improvement plan

**Scope:** Production releases for `openagents.com`

## Executive summary

The deployment system has three valid lanes, but recent production work has
used rolling replacement most often. Of 47 live targets with deployment
receipts since August 20, 2026, 26 used rolling replacement, 4 used direct
load, and 17 predate reliable lane typing or used the relup path. Across all
70 targets in the period, the classifier marked 39 for rolling replacement
and 19 as direct-load candidates. The remaining 12 targets had no usable
classification.

Rolling replacement is often correct because recent candidates combine
assets, configuration, migrations, release files, or other structural changes
with application code. It is not the correct default for every release.
Two recent candidates that the classifier identified as direct-load candidates
were rolled manually. That choice spent minutes replacing containers for
changes that the direct-load transaction could have applied in less than one
second.

The measured lane differences are large:

| Measurement | Sample | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Direct load, promotion to terminal state | 4 | 10.5 s | 33.6 s | 151.0 s |
| Direct-load fleet transaction | 4 | 0.29 s | 0.39 s | 0.88 s |
| Rolling replacement, promotion to live | 26 | 3.1 min | 8.6 min | 39.4 min |
| Forge candidate build for rolling targets | 26 | 8.4 s | 2.0 min | 2.7 min |
| Release gate wall time, most recent 15 receipts | 15 | 1 s | 1.7 min | 7.6 min |
| Production image build, successful recent builds | 26 | 4.1 min | 5.2 min | 8.9 min |

These measurements show three immediate priorities:

1. Select the lane before starting structural-release work. Use direct load
   for an allowlisted BEAM-only change, relup for a compatible application
   upgrade outside the allowlist, and rolling replacement only when the
   candidate changes the runtime structure.
2. Automate promotion with a narrowly scoped operator credential. Recent
   direct deployments spent 9 to 11 minutes waiting for a manual promotion
   even though promotion-to-live took 29 to 38 seconds.
3. Instrument and streamline rolling replacement. The current script rebuilds
   and pulls an image, restarts three nodes serially, and polls each node every
   20 seconds. The durable receipt does not retain the time spent in each node
   phase, so it cannot identify whether image pulls, container startup,
   clustering, or polling dominates the roll.

## Method and limitations

This audit uses the following evidence:

- Production target and deployment receipts from August 20 through August 27,
  2026.
- Local exact-SHA release gate receipts under `.git/openagents/release-gate/`.
- Successful Cloud Build records for the production image repository.
- The deployment policy in `docs/deploymodes.md` and the executable behavior in
  `ops/ci/gate.sh`, `ops/deploy/build-image-cloud.sh`,
  `ops/deploy/release-to-production.sh`, and
  `ops/deploy/fleet-startup.template.sh`.

The measurements have four limitations:

- `promotion-to-live` starts when an operator promotes a pushed target. It does
  not include the release gate, image build, or time waiting for promotion.
- `push-to-live` includes operator delay. It measures what a developer feels,
  but it does not isolate system execution time.
- Release gate stage durations are cached by input hash. A receipt's total wall
  time describes that invocation, while an individual cached stage can report
  the duration of an earlier execution. Do not add the stage durations to
  reconstruct the total.
- Many manually settled rolling receipts record a deployment duration of zero
  or a rounded assumption. This audit therefore uses target lifecycle times
  for rolling replacement and does not report a receipt-level rollout median.

## How the lanes should work

Use the narrowest lane that preserves the production invariants in
`docs/deploymodes.md`.

| Lane | Use it when | Do not use it when | Expected production work |
| --- | --- | --- | --- |
| Direct load | Every changed module is in the direct-load allowlist; the candidate changes only added or modified BEAM files; the application specification, release version, dependencies, toolchain, and structural paths are unchanged | The candidate deletes a module or changes assets, configuration, migrations, native code, dependencies, or release structure | Build the changed modules, prepare every node, deploy to a canary, and commit the same artifact set across the fleet without restarting containers |
| Relup | A pure Elixir application change is outside the direct allowlist, needs an OTP code-change callback, or changes supervised state compatibly; the forward and reverse release packages pass the topology preflight | The candidate changes assets, dependencies, migrations, native code, or has no safe upgrade path | Install the exact relup package one node at a time and retain the reverse package |
| Rolling replacement | The candidate changes `mix.exs`, `mix.lock`, runtime configuration, assets, migrations or other release `priv` content, `rel`, native code, the Dockerfile, dependencies, or the toolchain | The classifier proves the candidate is an allowlisted BEAM-only change | Build one immutable image and replace one healthy node at a time |

Published documentation under `priv/docs/**` is compiled into the allowlisted
documentation catalog and can use direct load when it causes no other
structural change. Source documentation, comments, and other uncompiled files
can produce a zero-module candidate and might require no production action.

The decision order is:

1. Use direct load when the classifier and preflight permit it.
2. Use relup when direct load is not permitted and the OTP upgrade is
   compatible.
3. Use rolling replacement for structural candidates or when either narrower
   lane refuses the candidate.

Never override a refusal to obtain a faster release. A refusal is evidence
that the candidate does not satisfy that lane's safety contract.

## Where the current time goes

### Direct load

The fleet transaction is already fast. The most recent production direct load
deployed one module across all three nodes in 381 ms. Its full
promotion-to-live interval was 28.9 seconds, including the Forge build.

The variable cost is the candidate build. In the four typed direct-load
receipts, the build took 10.0 to 149.4 seconds, with a median of 32.5 seconds.
The operator queue can cost more than the entire deployment. Three recent
direct releases took 9.0, 9.1, and 11.3 minutes from push to live, while their
promotion-to-live intervals were 151.0, 38.3, and 28.9 seconds.

Direct-load optimization should therefore target promotion latency and Forge
builder latency. Optimizing the subsecond fleet transaction will not improve
the developer's wait materially.

### Release gate

The most recent 15 gate receipts took 1 to 454 seconds, with a median of 103
seconds. A one-second gate means that every stage reused exact input evidence;
it does not mean the full test suite ran in one second. The broadest stage is
`mix precommit`: its cache input is the entire tree, so a new commit invalidates
it. A recent uncached run took about 4.2 minutes and executed 5,129 checks.

The production runbook's 30-to-60-minute gate estimate no longer describes the
recent measured range. Update that estimate only after the gate receipt reports
enough uncached samples to publish percentiles by candidate type.

### Production image build

Across 26 successful recent builds, Cloud Build took 246 to 536 seconds from
submission to completion, with a median of 314 seconds. The median queue delay
was 52 seconds, and the median build execution was 259 seconds.

The image path compiles the application and assets inside Docker, verifies the
packaged revision, and pushes the immutable image. A structural release also
causes the Forge builder to compile the candidate after promotion. Those two
builds currently run serially in the operator procedure and repeat some work.

### Three-node rolling replacement

After promotion, rolling targets took a median of 8.6 minutes to reach live.
The Forge candidate build accounts for about 2.0 minutes of that median. The
remaining interval includes operator coordination, three sequential node
replacements, and settlement.

For every node, the startup path performs the following costly operations:

1. Stop and remove the application container.
2. Prune unused images.
3. Pull the new production image.
4. Restart the Cloud SQL proxy and wait for it.
5. Start the application container.
6. Remove, prune, pull, and restart the builder container.
7. Rejoin the distributed Erlang cluster in a background loop.

The release script checks every other node, updates instance metadata, starts
the startup runner, and then checks health every 20 seconds. Across three
nodes, fixed polling alone adds up to 60 seconds of detection delay and an
expected delay of about 30 seconds. Because the receipt stores only `ready`
for each node, it cannot distinguish this delay from image transfer or startup.

## Why rolling replacement has become the default in practice

The observed behavior has four causes:

- Candidates often bundle application code with assets, configuration,
  migrations, or release files. One structural path makes the entire candidate
  a rolling replacement.
- Operators have not had a local, pre-promotion lane forecast that explains
  the classifier result before they spend time on a gate and image.
- The runbook presents the image pipeline as the primary short path even
  though direct load does not need a production image or node restart.
- Operators have used rolling replacement as a familiar fallback, including
  for at least two candidates that production classified as direct-load
  candidates.

The safety rules are not the problem. The workflow exposes the lane too late
and makes the broadest lane easier to start than the narrow lanes.

## Improvement plan

### Priority 0: Improve iteration time

1. **Add a preflight deployment plan command.** Given the current live SHA and
   a candidate SHA, print the selected lane, every structural reason, changed
   modules, deletions, version requirements, and required artifacts. Use the
   same classifier code as production. Make this the first runbook step.
2. **Automate explicit promotion.** Add a CLI command that obtains a short-lived
   `deployments:promote` credential, promotes one exact SHA, and waits for the
   target receipt. Keep promotion separate from push. This change removes the
   largest measured direct-load delay without weakening the approval boundary.
3. **Make the release command lane-aware.** For a direct candidate, run the
   direct preflight and promotion flow without building a container image. For
   a relup candidate, build and verify the exact release package. Start the
   image path only for a structural candidate.
4. **Keep independent changes in separate candidates.** Do not attach an asset,
   configuration, migration, or dependency change to an otherwise direct-load
   application change when the changes can ship independently. The structural
   file forces the combined candidate into rolling replacement.
5. **Report developer and system latency separately.** Publish push-to-live,
   push-to-promotion, promotion-to-build-complete, deployment transaction, and
   promotion-to-live. This split makes operator delay visible without hiding
   the developer's actual wait.

### Priority 1: Speed up full rolling replacement

1. **Persist phase and node timings.** Record gate start and finish, Cloud Build
   queue and execution, Forge build, authorization, and settlement. For every
   node, record drain, image pull, application start, health, cluster rejoin,
   and builder start. Replace zero-duration manual receipts with measured
   monotonic durations.
2. **Pre-pull the immutable image.** Pull and verify the target digest on all
   three nodes while the old containers still serve traffic. Drain and restart
   one node only after every node has the verified image. Retain the previous
   digest for rollback and do not prune it before the new node is healthy.
3. **Stop restarting unchanged support containers.** Keep the Cloud SQL proxy
   running when its image and arguments are unchanged. Restart the builder only
   when its image digest or configuration changed. These processes do not need
   to share the application container's release cadence.
4. **Use adaptive health polling.** Poll every 2 seconds during the first 30
   seconds, then back off to 5 seconds with jitter while preserving the current
   10-minute refusal timeout. This removes most fixed detection delay without
   weakening readiness checks.
5. **Run independent builds concurrently.** After the exact-SHA gate passes,
   start the immutable image build and Forge candidate build together for a
   forecast structural candidate. Bind both receipts to the same SHA and do not
   authorize replacement until both succeed. At current medians, serial builds
   cost about 7.2 minutes; overlap can approach the slower 5.2-minute build.
6. **Use one rolling coordinator.** Move the shell loop behind the existing
   rolling-replacement coordinator so authorization, other-node health,
   idempotent node skipping, timing, and settlement share one implementation.
   Keep the script as an operator entry point instead of a second state machine.

### Priority 2: Reduce structural-release frequency

1. **Review the direct-load allowlist with evidence.** Add a namespace only
   after tests prove state compatibility, rollback, and fleet convergence. Do
   not widen the allowlist to make the classifier quiet.
2. **Evaluate an immutable asset deployment lane.** Fingerprinted CSS and
   JavaScript could move independently if the application serves an atomic
   asset manifest and retains the previous bundle through rollback. Until that
   design exists and has executable invariants, assets remain structural.
3. **Reduce duplicated compilation.** Let the image build consume a verified
   candidate artifact or let both builders share content-addressed compilation
   inputs. Preserve independent revision verification at the final image.
4. **Split the builder lifecycle from the web release.** Pin a builder digest
   separately so routine web rolls do not pull and restart an unchanged builder
   on every node.

## Proposed targets

Use the following targets after phase timing lands and produces at least 20
valid samples per lane:

| Metric | Initial target |
| --- | ---: |
| Direct-load push to promotion | p50 under 15 s |
| Direct-load promotion to live | p50 under 45 s; p95 under 2 min |
| Direct-load fleet transaction | p95 under 2 s |
| Relup package ready to fleet live | p50 under 90 s |
| Rolling promotion to live | p50 under 6 min; p95 under 15 min |
| Production image submission to published digest | p50 under 4 min |
| Per-node image-ready to healthy | p50 under 45 s |

Do not set an end-to-end rolling target until the receipts include the gate,
image build, operator wait, and per-node phases. The current data can measure
those components separately, but it cannot reconstruct every historical full
release reliably.

## Recommended runbook shape

Replace the current one-size-fits-all sequence with this operator flow:

1. Select an exact candidate SHA and run the local deployment-plan preflight.
2. Run `mix precommit` and the qualification required for the selected lane.
3. Push the candidate to the forge.
4. Promote the exact SHA with the scoped command.
5. Follow the lane chosen by the production classifier:
   - Direct load: wait for the transactional receipt and verify production.
   - Relup: install the verified package one node at a time, then verify and
     settle.
   - Rolling replacement: build or resolve the immutable image, pre-pull it,
     replace one node at a time, then verify and settle.
6. Confirm the public revision, three-node convergence, and durable receipt.

This flow keeps push, promotion, and deployment separate. It makes the common
BEAM-only path fast and preserves rolling replacement as the safe path for
structural change.
