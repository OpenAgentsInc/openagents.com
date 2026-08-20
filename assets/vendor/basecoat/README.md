# Basecoat (vendored)

Third-party source. **Do not edit these files.**

- Upstream: [hunvreus/basecoat](https://github.com/hunvreus/basecoat)
- Pinned tag: `1.0.2`
- Commit: `6953a4a`
- License: MIT, Copyright (c) 2025 Ronan Berder — see `LICENSE.md`
- Vendored: 2026-08-17

## What is here, and what is not

Copied from upstream `src/css/`:

- `base/base.css` — shadcn-compatible token contract and `@theme` mapping
- `components/*.css` — component structure: layout, accessibility selectors, and
  behavior hooks, carrying no color and no radius

Deliberately **not** vendored:

- `src/css/styles/*` — the Vega/Nova/Maia/Lyra/Mira/Luma/Sera/Rhea visual packs.
  Sarah writes its own pack at `assets/css/style-sarah.css`. Importing one of
  theirs and overriding it would leave dead visual rules in the bundle and make
  Sarah's identity a diff against another product's defaults.
- `src/js/*` — no Basecoat JavaScript is loaded. The only component Sarah's
  surfaces would need it for is `dropdown-menu`, and the account menu uses the
  native `popover` API instead, which is required to work without custom
  client-side JavaScript. Taking zero Basecoat JS also removes the LiveView
  DOM-patching risk class: no `MutationObserver`, no `basecoat.initAll()` on
  reconnect, no cached-DOM rehydration.

## Import rule

`assets/css/app.css` imports `base/base.css` plus **individually named**
component files. Component CSS lives in `@layer components` and is emitted
whether or not the class appears in markup, so importing the full set costs
about 13.5 KB gzip against about 7.4 KB for the components Sarah actually uses.
Never import `basecoat.css`, `basecoat-base.css`, or `basecoat-components.css`.

Adding an import is a deliberate act tied to a surface that needs it.

## Upgrading

1. Re-copy `src/css/base` and `src/css/components` from the new upstream tag.
2. Update the tag, commit, and date above.
3. Rebuild and check the component gallery at `/dev/ui` (dev only) against
   `DESIGN.md` — the shared corner radius, the sanctioned depth tokens, and the
   reserved semantic colors.
4. Run `mix precommit`, which includes the CSS contract guard.

See `docs/decisions/0003-basecoat-component-library.md`.
