# Design Principles

Use native Apple controls and behavior with the put.io theme. The shared design
package owns colors, typography, spacing, motion, and Phosphor icons; Apple owns
control geometry, navigation, focus, and presentation.

[package.json](package.json) pins the design package. The adopted
[Apple contract](https://github.com/putdotio/putio-design/blob/v3.3.0/platforms/apple/DESIGN.md)
sets the platform rules. Follow [Contributing](contributing.md#design-tokens)
when updating the package or its generated adapter.

## Controls and content

- Prefer stock controls, lists, forms, sheets, and navigation. Let native lists
  own insets, separators, row height, and disclosure. `NavigationLink` supplies
  folder disclosure; edit-mode and Trash rows have no navigation accessory.
- Content actions use bordered styles. Reserve stock glass for standalone
  floating controls over media. Toasts and Up Next own their surface; their
  child controls must not add another glass layer. Keep plain glass neutral
  and use at most one prominent glass capsule per screen.
- Set the app accent once. System back controls, selection, and ordinary actions
  inherit it; destructive and success actions retain their semantic roles.
- Keep app content dark and opaque. Use generated foreground roles for authored
  text and native geometry for controls.
- Let `Gauge` and `ProgressView` own their tracks and dimensions. The download
  control's minimum hit target does not constrain its intrinsic ring. Keep
  queued, downloading, downloaded, idle, and failed states distinct; failure
  offers retry with an accessible reason.
- Let `AVPlayerViewController` own video transport, AirPlay, and Picture in
  Picture. Keep over-video text in the
  [player palette](Apps/iOS/Sources/VideoPlayback.swift) and preserve the app
  accent on transport controls.

## Typography and layout

Use `putioFont` for app-authored content. Brand fonts are optional; preserve system
and per-glyph fallback, including raw filenames. System navigation titles, tab
labels, search fields, and time displays retain system typography.

Use the generated semantic numeric roles for tabular figures. Their
[generator](scripts/generate-design-tokens.ts) owns platform font selection;
do not introduce a separate tvOS monospace face.

Structural spacing, overscan, borders, radii, and minimum interaction geometry
remain fixed. Content, adjacent icons, and meaningful gaps scale through
`PutioScaledMetric` with an explicit Dynamic Type text style. Add a semantic
`PutioMetricRole` when needed instead of scaling the entire spacing ramp.

File-type icons use yellow Phosphor assets. Preserve native tab glyph sizing;
Search keeps the system glyph.

## tvOS and watchOS

Use stock tvOS focus styles for lift, shadow, and parallax. Secondary controls
keep the system focus fill so accent text remains readable. Non-control surfaces
use solid backgrounds and TV token roles. Rows acting as controls use the stock
card style.

[tvOverscanPadding](Apps/tvOS/Sources/TVLayout.swift) tops up the safe area to the
token overscan ratios; adding both in full would double the margin. Device-code
sign-in uses tabular figures and a solid surface; sign-out uses the native dialog.

Watch interactions are counts, states, and remote control, with one action per
screen. File browsing and text entry belong on the phone.

## Feature scope

Design contracts do not authorize implementing a feature early. The owning
issues define scope for [TV browsing](https://github.com/putdotio/putio-ios/issues/141),
[TV playback](https://github.com/putdotio/putio-ios/issues/142),
[TV settings](https://github.com/putdotio/putio-ios/issues/143),
[the watch companion](https://github.com/putdotio/putio-ios/issues/154), and
[Continue Watching](https://github.com/putdotio/putio-ios/issues/152). Preserve the
TV settings exclusion of playback-type settings and Continue Watching's
post-v1 scope when reconciling older design cards.

## Verification

Run `mise run verify`. Intentional component changes require inspected,
re-recorded iOS/tvOS baselines through the [harness](docs/harness.md).
Inspect native materials, focus, and Dynamic Type in the affected simulator;
off-screen snapshots cannot prove Liquid Glass. Use the Files journey when
changing disclosure, Trash, or playback interactions.
