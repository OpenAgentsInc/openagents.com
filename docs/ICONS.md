# Icon policy

Date: 2026-08-20

Status: Current

OpenAgents uses one component entry point and two governed glyph tiers. Render
every glyph with `OpenAgentsWeb.UI.icon/1`. Never paste an SVG into a template,
call an icon library module, add an icon font, or introduce a third source.

## Tier 1: Apps SDK UI

Use the vendored Apps SDK UI set in `priv/icons` first. These files are pinned,
same-origin, and covered by `priv/icons/LICENSE`. `OpenAgentsWeb.Icons` embeds
them and fails on unknown names.

To add or upgrade a glyph:

1. Check out `openai/apps-sdk-ui` at the reviewed commit.
2. Run `mix openagents.icons.vendor <path-to-apps-sdk-ui>`.
3. Update the commit, date, and count in `priv/icons/README.md`.
4. Run `mix precommit`.

## Tier 2: Heroicons

Use a `hero-*` name only when the Apps SDK set has no suitable glyph. Heroicons
is pinned to revision `0435d4ca364a608cc75e2f8683d374e55abbae26` and enters
the CSS bundle through `assets/vendor/heroicons.js`. The same `icon/1` component
renders the fallback, so accessibility and sizing stay governed.

Before you add a fallback use:

1. Record the call site, glyph, and missing Apps SDK concept in the inventory
   below.
2. Confirm that no existing Apps SDK glyph communicates the action.
3. Add a test for the control's accessible name or adjacent visible label.
4. Run `mix precommit`.

### Fallback inventory

No product surface currently uses a Heroicons fallback. The dependency remains
available as the documented second tier, and the CSS contract test prevents it
from becoming a separate component system.

## Brand marks

Brand marks live in `priv/brand`, outside both generic tiers. Use one only to
identify the service reached by an action. Render it through `icon/1` with a
`brand-*` name, and follow the attribution and trademark rules in
`priv/brand/README.md`.

## Octicons

Issue-state glyphs live in `priv/octicons`, vendored verbatim from
[Primer Octicons](https://github.com/primer/octicons) (MIT) at the commit
recorded in `priv/octicons/README.md`. They render through `icon/1` under
`octicon-*` names.

OpenAgents is a GitHub-compatible forge, so issue state is domain vocabulary:
open takes `octicon-issue-opened` and a completed close takes
`octicon-issue-closed`. Neither governed tier carries those concepts — the Apps
SDK set has no issue glyph, and Heroicons has no circle-dot. State color comes
from palette tokens at the call site (`--success` for open, `--done` for
closed), never from the file.

Adding or upgrading an octicon follows the same rule as every other tier:
copy the upstream file at the pinned commit, update the README's commit, date,
and count, and run `mix precommit`.

## Accessibility

A glyph beside visible words is decorative and needs no label. Put
`aria-label` on an icon-only control. Pass `label` to `icon/1` only when the
glyph itself is the complete, noninteractive message.
