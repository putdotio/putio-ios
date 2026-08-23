# Design Principles

The rule for every Apple surface in this repository:

**Native platform elements, put.io theme on top. Never port the web app's
component recipes.**

`@putdotio/design` is canonical for *values* — colors, type scale, spacing,
radii, motion, icons (Phosphor), and the dark-only decision (#82). Its
`components.css` and the web previews are the **web binding** of those values,
not a spec for native controls. The old "Claude design" concept galleries were
concepts, nothing more.

This repo sits in the native tier of put.io's design binding model: web
surfaces carry the full put.io component system; native apps (this repo,
Android) take tokens only and build every component from the platform's human
interface guidelines; Roku takes tokens with more room for put.io conventions;
the web TV app applies the design system restrained to a generic 10-foot look.

## What this means in practice

- Use stock SwiftUI controls, containers, and presentations: `Button` styles,
  `List`, `Form`, `Toggle`, `Picker`, `.sheet`, `ProgressView`,
  `ContentUnavailableView`, system materials. If Apple ships the element, use
  Apple's element.
- Liquid Glass belongs to the floating layer, per the HIG: on iOS, buttons use
  `.glassProminent`/`.glass` and floating overlays (toasts) use `glassEffect`.
  The content layer — lists, rows, forms, screen states — stays opaque; do not
  put glass on content.
- Theme through the generated adapter only: tint is brand yellow
  (`PutioTheme.Colors.accent`), file/type icons are yellow Phosphor glyphs,
  text uses the brand faces via `putioFont`, semantic colors come from
  `PutioTheme`. No hand-picked values.
- Follow the Human Interface Guidelines for layout: system list metrics,
  breathing room, minimum touch targets, and Dynamic Type everywhere — every
  icon and gap that sits next to text scales with the text
  (`PutioScaledMetric`).
- Do not invent custom-painted buttons, fields, switches, or sheet chrome on
  iOS or watchOS. Custom drawing is reserved for genuinely brandless gaps
  (e.g. nothing in UIKit/SwiftUI renders a file row — compose one from native
  parts, yellow icon included).
- The shipping App Store app is the look reference: native iOS chrome,
  put.io color, type, and icons on top.

## The tvOS exception (narrowed)

**Buttons are system Liquid Glass on every shell — including tvOS and
watchOS — with the system focus treatment.** This is a deliberate product
override (2026-08) of the upstream TV contract's "solid focus, no materials"
rule for buttons: native tvOS focus behavior wins over web-TV parity.

The rest of the TV contract in `@putdotio/design`'s DESIGN.md still stands
for non-button TV surfaces: solid token fills for rows, toasts, and modals,
one `tv.radius`, row focus as a solid fill. TV has no mono face; numerics use
GT America tabular figures.

The product's TV family feel is the shipped TV app's generic list-first
10-foot interface: tvOS aligns with that direction — same content shapes,
density, and calm file-browser character — without giving up tvOS platform
characteristics like the system focus treatment. Revisit the non-button rules
when the tvOS browse slice lands and the upstream contract is updated.

## Verification

Component and theming changes are asserted by the snapshot gallery
(`mise run harness -- test --platform <ios|tvos>`) and reviewed as image
diffs. If a change makes a control look less like stock iOS, it is wrong
unless this document says otherwise.
