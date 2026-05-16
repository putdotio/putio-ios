# Styling

## Recommendation

- **UIKit iOS app**: stay with the existing storyboards / programmatic UIKit
  + asset catalog patterns. See `Putio/Features` for prior art.
- **SwiftUI tvOS target (`PutioTV/`)**: SwiftUI primitives only. Apply put.io
  design tokens through the `PutioTV.Design` namespace. Liquid Glass material
  for navigation/control layers, never for content backgrounds.

## Why

The TV surface must read from across the room. Apple's tvOS 26 focus engine
and Liquid Glass already solve hierarchy when used correctly. Custom chrome
that fights the system material is the most common phase-one parity slip.

## Rules

- Color tokens live in `PutioTV/Design/Colors.swift` and resolve through
  `Color.put` accessors (`Color.put.brand`, `Color.put.accentYellow`).
- Typography is `.title`, `.largeTitle` etc. with a small repo-local
  `Font.put.*` for explicit large-distance overrides.
- Lucide icons via `PutioTV/Design/Components/LucideIcon.swift`. Prefer the
  SVG asset wrapper unless an SF Symbol is a clearer system fit (search, info).
- Focusable rows go through `FocusableRowStyle`; do not implement focus
  highlight manually.
- Liquid Glass: `.glassBackgroundEffect()` on toolbars, menus, transient
  panels. Never on a list cell's content surface.
- No custom controls for video — let `AVPlayerViewController` own the chrome.

## Anti-patterns

- Hex colours in feature code.
- Hard-coded font sizes outside the design tokens.
- Custom blur/material backdrops behind a row.
- Per-screen focus-state booleans.

## Examples

- `PutioTV/Design/Colors.swift`
- `PutioTV/Design/Typography.swift`
- `PutioTV/Design/Components/FocusableRowStyle.swift`
- `PutioTV/Design/Components/GlassToolbar.swift`
