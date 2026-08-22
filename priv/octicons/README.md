# Octicons (vendored)

Generated files. **Do not edit these by hand.**

- Upstream: [primer/octicons](https://github.com/primer/octicons)
- Commit: `0e21a4c2d8449102f10e533d241f04797af0914c`
- License: MIT, Copyright GitHub, Inc. — see upstream repository
- Vendored: 2026-08-22
- Count: 2 glyphs

## Why this set exists

OpenAgents is a GitHub-compatible forge. Issue state iconography is a domain
contract — the green circle-dot for open and the purple check-circle for closed
are what users expect on an issues surface — and neither governed tier carries
it:

- The Apps SDK UI set (`priv/icons`) has no issue-state glyph.
- Heroicons (the `hero-*` fallback) has no circle-dot and its check-circle
  reads as success feedback, not issue state.

These two glyphs are vendored verbatim from Primer Octicons at the pinned
commit above. To add or upgrade one, copy the matching `*-16.svg` from the
upstream checkout, update the commit, date, and count here, update
`docs/ICONS.md`, and run `mix precommit`.

`OpenAgentsWeb.Icons` embeds these files under `octicon-*` names, so call
sites render `<.icon name="octicon-issue-opened" />`. State color comes from
palette tokens at the call site, never from the file.
