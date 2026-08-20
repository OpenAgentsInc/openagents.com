# Status

[Status](/status) reports whether the system is healthy, without disclosing its
internals.

## What it shows

Fleet nodes and their convergence, the forge pipeline, and the push-to-live
loop time.

## Content-free by design

The page reports counts, states, and durations. It does not name operators,
modules, hostnames, or repositories. A status page is read by people who are
not signed in, so it must be safe for the least-trusted reader.

## The API

The same projection is available as JSON at [`/api/status`](/api/status), with
the same disclosure rules.
