# Gate 11 release fallback evidence

Date: 2026-08-20

Implementation SHA: `2e1c9240d0b172501a93bef7b02e934a63b447ae`

Gate 11 passed locally on the exact implementation commit. This evidence set
is content-free and contains no credentials, database URLs, hostnames, private
repository content, conversation content, or staging data.

## Evidence

- `release-gate-receipt.json` is the immutable result copied from the owned
  exact-SHA release gate. Test and production compilation, precommit, all 14
  distributed tests, 17 browser tests, 42 focused direct-transaction tests,
  four rolling-replacement tests, 68 contract tests, and packaged release
  startup passed without retries.
- `relup-proof.json` records the checksums for explicit `0.1.0` and `0.2.0`
  release artifacts and the generated two-way relup. The exact-SHA gate also
  proved upgrade, downgrade, and re-upgrade on a live packaged node and
  recovery after interrupting an install beyond its point of no return.
- `rolling-and-image-proof.json` records the local image digest and the rolling
  recovery cases exercised by the exact-SHA gate.

The release startup and relup drills used one newly provisioned disposable
PostgreSQL role and database. No image was pushed to a registry, and no staging
or production deployment occurred.
