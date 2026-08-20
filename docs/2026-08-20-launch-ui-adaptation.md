# Launch UI adaptation

*2026-08-20*

`OpenAgentsWeb.UI.Landing` is adapted from [Launch UI][launch-ui], MIT-licensed,
© 2024 Mikolaj Dobrucki. This document records what was taken, what was not, and
why — so a later reader can tell which decisions are inherited and which are
ours.

## What "adapted" means here

Nothing was copied. Launch UI is React and Tailwind: each component is a
`class-variance-authority` variant map over utility strings, several depend on
Radix primitives, and the section components ship with their own default content
baked in. None of that survives a move to HEEx and a stylesheet.

What carried over is **composition and visual judgement**: what a hero contains
and in what order, that a glow is two stacked ellipses rather than one, that a
mockup frame is a second wider border rather than a drawn device, that a feature
grid divides four/three/two by width and carries no cell borders, that a pricing
column is lit by a fading top rule rather than an accent fill.

The MIT licence requires the copyright notice be retained. It is, in the module
docs, in the stylesheet section header, and here.

## Inventory

Thirteen components, all catalogued and demoed at `/components`:

| Ours | Source |
| --- | --- |
| `section/1` | `ui/section.tsx` |
| `glow/1` | `ui/glow.tsx` |
| `beam/1` | `ui/beam.tsx` |
| `mockup/1` | `ui/mockup.tsx` (frame + mockup collapsed into one) |
| `hero/1` | `sections/hero/default.tsx` |
| `feature_grid/1` | `sections/items/default.tsx` + `ui/item.tsx` |
| `stats/1` | `sections/stats/default.tsx` |
| `pricing_column/1` | `ui/pricing-column.tsx` |
| `faq/1` | `sections/faq/default.tsx` + `ui/accordion.tsx` |
| `cta/1` | `sections/cta/default.tsx` |
| `logo_wall/1` | `sections/logos/default.tsx` |
| `landing_footer/1` | `sections/footer/default.tsx` |
| `layout_lines/1` | `ui/layout-lines.tsx` |

Not adapted: `navbar`, `navigation-menu`, `sheet`, `dropdown-menu`,
`mode-toggle`, `screenshot`, `logo`, `link-button`, `button`, `badge`, `card`,
`item`. The navigation set duplicates the application's own sidebar and command
bar, which already exist and are already the thing a visitor sees on every other
page. The rest already exist in `OpenAgentsWeb.UI` or are Next.js-specific.

## Deliberate departures

### Tokens, not a second palette

Launch UI paints with `brand`, `brand-foreground`, and five layered `glass-*`
gradients over `card`. Adopting those would put a second colour system beside
the one every other surface uses, and a landing page that does not look like the
product it advertises is worse than a plainer one that does.

Every value in the landing stylesheet resolves to an existing token. Where the
source reaches for a brand hue — the glow, the stat value, the pricing rule —
ours uses `--text-primary` through `color-mix`, so the same component is correct
in both themes without a second set of declarations.

One consequence worth stating: the glow carries `opacity: 0.35` in light mode.
The same intensity that reads as a lit backdrop on a dark surface reads as a
stain on a white one, and the source solves this by having a separate brand
colour per theme.

### No JavaScript

The FAQ is a native `<details>` rather than a Radix accordion, and there is no
adapted navbar, so nothing on a landing page waits on a bundle. Marketing pages
are the first thing a visitor loads and the most likely to be read on a slow
connection.

This also removes the `--radix-accordion-content-height` animation the source
uses. A native disclosure snaps open. That is a real loss and a deliberate one:
animating it requires either JavaScript measurement or `interpolate-size`, which
is not yet broadly supported.

### Motion is decorative

`appear` and `appear-zoom` are ported, including the blur-out that makes the
source's entrance feel like focus rather than a slide. Both are guarded by
`prefers-reduced-motion`, and because they are purely decorative, the guard
simply drops the animation and leaves the element at its final state rather than
substituting a shorter one.

## The homepage is built from these

`OpenAgentsWeb.HomeLive` composes catalogued components rather than page-local
markup, so the homepage and the component library cannot drift: changing a
landing component changes the homepage, and the library demonstrates the same
thing a visitor sees.

The hero's headline and description are unchanged from what the page already
said. The other bands are new and carry new copy, which was unavoidable — a
feature grid with no features is not a demonstration of anything.

## What is not done

- **No stats band on the homepage.** `stats/1` exists and is demoed, but every
  figure that could go in it would be either a vanity metric or one nobody has
  agreed to publish. An empty or invented statistics row is worse than none.
- **No pricing page.** `pricing_column/1` exists and is demoed; there is no
  pricing to state yet.
- **The demos are contained.** Landing bands are built to own a viewport, and
  the component library shows them inside a frame at reduced rhythm. The frame
  is the honest part — it says "scaled-down view" instead of pretending the
  documentation column is a page.

[launch-ui]: https://github.com/launch-ui/launch-ui
