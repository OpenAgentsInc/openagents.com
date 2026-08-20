# ADR 0005: Use Basecoat and one OpenAgents component system

Date: 2026-08-20

Status: Accepted

## Context

The application previously combined DaisyUI, hand-written classes, and
persona-named component wrappers. Conflicting cascade layers made variants
render incorrectly and created multiple ways to build the same control.

## Decision

Use the pinned, vendored Basecoat component CSS as the structural foundation
and one OpenAgents style pack for product identity. Import only the Basecoat
component files that a surface uses. Wrap the system in one Phoenix component
module and use those components before adding surface-specific markup.

Do not add DaisyUI, another component library, remote fonts, icon fonts, or a
second Markdown presentation stack. The generic component module is
`OpenAgentsWeb.UI`, and the product style pack is `assets/css/openagents.css`.
Keep Sarah-specific visual copy only where it identifies the persona.

## Consequences

- Components share one variant, accessibility, token, and interaction model.
- Vendored Basecoat remains separately licensed and must not be patched in
  place.
- The application owns its identity in the style pack rather than in vendored
  source.
- Component and screenshot regression tests can target one catalog.
