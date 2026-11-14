# Design Principles

These rules hold for the iOS redesign on `next`. The shared design package owns
colors, type, spacing, motion, and Phosphor icons;
[package.json](package.json) pins it and the
[generated adapter](Packages/PutioCore/Sources/PutioCore/Generated/PutioTheme+Generated.swift)
carries its values. The adopted
[Apple contract](https://github.com/putdotio/putio-design/blob/v3.3.0/platforms/apple/DESIGN.md)
sets the platform rules. Change tokens through
[Contributing](CONTRIBUTING.md#design-tokens).

## iOS

- **Native first.** Every control is the stock iOS one. put.io supplies color,
  type, glyphs, and copy; Apple owns geometry, navigation, and presentation.
- **Yellow marks four things.** File glyphs, the selected tab, checkmarks, and
  the one primary button of a screen, sheet, or alert. Everything else is
  neutral. Account screens have no yellow.
- **Glass only on chrome.** The toolbar, tab bar, menus, and toast. A control
  inside the toast adds no second glass layer.
- **Tab bar.** It minimizes on scroll down, as the stock iPhone tab bar does.
  Boards draw it full; a minimized bar in a scrolled capture is not a
  difference.
- **Type.** GT America for content; Berkeley Mono for sizes, counts, and times.
  Text stops growing at XX Large through the window override in
  [PutioApp](Apps/iOS/Sources/App/PutioApp.swift).
- **Layout follows size classes.** Compact width is one pane; regular width
  adds a detail column. No device checks.
- **Copy.** A string ships only if a design shows it. It records its Android
  string key, or `ios-only` with a reason when Android has none. A string no
  design shows blocks the change.
- **Video.** put.io controls over `AVPlayer`, not the system player screen.
  AirPlay stays the system route button.
- **Product lines.** No Transfers UI. Moving to Trash never confirms; only
  permanent delete confirms.

The redesign lands on `next` only.

## tvOS and watchOS

Use stock tvOS focus styles for lift, shadow, and parallax. Secondary controls
keep the system focus fill so accent text remains readable. Non-control surfaces
use solid backgrounds and TV token roles. Rows acting as controls use the stock
card style.

[tvOverscanPadding](Apps/tvOS/Sources/Components/TVLayout.swift) tops up the safe area to the
token overscan ratios; adding both in full would double the margin. Device-code
sign-in uses tabular figures and a solid surface; sign-out uses the native dialog.
Settings rows put the label left and the value right: two-state values cycle on
select, larger choices open a full-screen chooser, and there are no toggles.
Destructive actions confirm in a centered alert. File rows open on select and
offer their actions on a long press, in a centered alert; Trash moves are
recoverable and skip the confirmation. Search uses the system keyboard from
`.searchable`, and its results reuse the browser's rows.
Videos play in the system player, which owns transport, subtitles, audio, and
speed. A saved position asks first in a centered pre-play overlay: the raw
filename, a progress preview of the focused choice, and two stacked buttons with
the system focus fill. Up Next uses the same overlay shape.

Watch interactions are counts, states, and remote control, with one action per
screen. File browsing and text entry belong on the phone.

## Feature scope

Design contracts do not authorize implementing a feature early. The owning
issues define scope for [TV browsing](https://github.com/putdotio/putio-ios/issues/141),
[TV playback](https://github.com/putdotio/putio-ios/issues/142),
[TV settings](https://github.com/putdotio/putio-ios/issues/143),
[the watch companion](https://github.com/putdotio/putio-ios/issues/154), and
[Continue Watching](https://github.com/putdotio/putio-ios/issues/152); product
rules live in the put.io Notion
[Mobile app](https://app.notion.com/p/3ded546ba2f58193a18bd3c42b4d5504) and
[Settings contract](https://app.notion.com/p/3ded546ba2f5812485d9d597fbcc1a80)
pages.

## Verification

Component and theming changes follow the
[proof table](AGENTS.md#verification-and-completion): intentional visual changes
need inspected, re-recorded baselines through the [harness](.agents/skills/verify-putio-apple/references/snapshots.md).
Off-screen snapshots cannot prove Liquid Glass; inspect materials and Dynamic
Type in the simulator.
