# Component library

Date: 2026-08-20

Status: Current

The public catalog at `/components` is the executable inventory of reusable
HEEx components. `OpenAgentsWeb.ComponentCatalog` supplies its navigation,
`OpenAgentsWeb.ComponentsLive` renders every demo, and
`test/openagents_web/component_catalog_test.exs` fails when a public component
is absent from the catalog.

## Sanctioned system

New product interface work starts in `OpenAgentsWeb.UI`. Its components wrap
the pinned Basecoat styles imported by `assets/css/app.css` and receive product
identity from `assets/css/openagents.css`.

The current `OpenAgentsWeb.UI` inventory is:

| Component | Purpose |
| --- | --- |
| `button/1`, `text_button/1` | Boxed, link, chip, destructive, and primary actions |
| `input/1`, `textarea/1`, `label/1`, `field/1` | Form-aware controls and labeled groups |
| `header/1`, `table/1`, `list/1` | Page headings and structured data |
| `alert/1`, `badge/1`, `status_indicator/1` | Explicit feedback and semantic state |
| `card/1`, `frame/1` | Bounded content and decorative framing |
| `avatar/1`, `item/1`, `event_header/1` | Identity and activity rows |
| `empty/1`, `kbd/1`, `menu/1` | Empty states, key hints, and native-popover menus |
| `audio_player/1` | Accessible native audio control in the product frame |
| `icon/1` | Governed Apps SDK glyphs and documented Heroicons fallbacks |

`OpenAgentsWeb.Layouts` owns `app/1`, `flash_group/1`, `command_bar/1`,
and `account_control/1`. Product templates begin with `Layouts.app` and never
render `flash_group/1` directly. The command bar exposes one system, light, and
dark preference control over exactly two owned palettes. The system choice
stores no override and follows `prefers-color-scheme`. The synchronous theme
bootstrap in `root.html.heex` applies an explicit choice before the first paint
and synchronizes it across tabs.

## Specialized components

`OpenAgentsWeb.Components.RepoHeader.repo_header/1` is the only catalogued
forge-specific component. Surface-specific components can live in a focused
module when they encode real domain composition rather than a generic control.

## Extension rules

1. Search `OpenAgentsWeb.UI` and `/components` before creating a component.
2. Extend `OpenAgentsWeb.UI` for a reusable primitive; keep feature composition
   in a feature module.
3. Use an individually imported Basecoat component stylesheet only when the
   component needs it. Never import the aggregate Basecoat bundles.
4. Put OpenAgents-owned component styles in `assets/css/openagents.css`; do not
   patch `assets/vendor/basecoat/`.
5. Use `OpenAgentsWeb.UI.icon/1` and follow the two-tier policy in `ICONS.md`.
   Do not add an icon font, a third glyph library, or handwritten SVG in a
   template.
6. Give every icon-only action an accessible name. Decorative icons beside text
   remain hidden from accessibility APIs.
7. Add the component to `OpenAgentsWeb.ComponentCatalog`, add its demo to
   `OpenAgentsWeb.ComponentsLive`, and add behavior/accessibility tests in the
   same change.
8. Keep forms on `Phoenix.Component.to_form/2`; use LiveView streams for
   collections and stable DOM IDs for testable controls.

## Domain composition candidates

Issue, project, and code surfaces currently compose generic controls directly.
Create new domain components only when repeated behavior justifies them. Likely
candidates are issue rows, comment threads, label controls, project columns,
repository breadcrumbs, file rows, commit rows, and bounded diff panels.

The compiled CSS contract test proves that Basecoat geometry precedes the
OpenAgents style pack, every supported button variant survives compilation, no
retired palette alias survives, both owned themes compile, the operating-system
fallback compiles, and no third theme selector enters the bundle.

The root theme bootstrap is the only inline script. The browser pipeline creates
a unique CSP nonce for each response, places it in `script-src`, and binds it to
that bootstrap. Do not admit another inline script with the nonce.

See [the UI roadmap](issues-projects-ui-roadmap.md),
[ADR 0005](decisions/0005-use-basecoat-and-one-component-system.md), and the
[hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
