# Design Principles

The rule for every Apple surface in this repository:

**Native platform elements, put.io theme on top. Never port the web app's
component recipes.**

`@putdotio/design` is canonical for *values* — colors, type scale, spacing,
radii, motion, icons (Phosphor), and the dark-only decision (#82). Its
`components.css` and the web previews are the **web binding** of those values,
not a spec for native controls. The old "Claude design" concept galleries were
concepts, nothing more.

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

## The tvOS exception

The TV contract in `@putdotio/design`'s DESIGN.md stands: solid token
surfaces, no translucent materials, one `tv.radius`, focus expressed as a
solid fill plus a border step — never scale, lift, or halo. The system tvOS
focus style lifts and scales, so TV keeps the painted treatment. TV has no
mono face; numerics use GT America tabular figures.

## Verification

Component and theming changes are asserted by the snapshot gallery
(`mise run harness -- test --platform <ios|tvos>`) and reviewed as image
diffs. If a change makes a control look less like stock iOS, it is wrong
unless this document says otherwise.
