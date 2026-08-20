# Icons (vendored)

Generated files. **Do not edit these by hand.**

- Upstream: [openai/apps-sdk-ui](https://github.com/openai/apps-sdk-ui)
- Commit: `0f00143`
- License: MIT, Copyright 2025 OpenAI — see `LICENSE`
- Vendored: 2026-08-17
- Count: 755 glyphs

## How these were produced

Upstream ships one React component per glyph under
`src/components/Icon/svg/`, each drawing a `currentColor` SVG sized at `1em`.
Sarah has no React and no `node_modules`, so the components cannot be consumed
as published. `mix openagents.icons.vendor <path-to-apps-sdk-ui>` converts them:

- JSX attribute names become their SVG spelling (`fillRule` → `fill-rule`, and
  the rest);
- JSX expression values (`opacity={0.4}`) become quoted strings;
- `{...props}` is dropped;
- each glyph keeps its own `viewBox` — 730 are `0 0 24 24`, but 25 are not;
- element `id`s are namespaced per glyph, so one icon's `clipPath` cannot
  capture another's. Inlining the *same* glyph twice still duplicates its ids;
  that matches upstream behaviour and has not mattered in practice.

The task refuses to run against a directory that is not an apps-sdk-ui
checkout, and raises on any JSX it was not built to handle, so an upstream
change fails loudly rather than emitting a subtly wrong glyph.

## Upgrading

1. Pull the upstream checkout to the new commit.
2. Re-run `mix openagents.icons.vendor <path>`. It clears the previous set first, so
   glyphs deleted upstream do not linger.
3. Update the commit and date above.
4. Run `mix precommit`. The icon tests fail if a glyph a surface depends on has
   disappeared.

## Using them

See `docs/ICONS.md`. In short: `<.icon name="arrow-up" />`, and never paste SVG
into a surface.
