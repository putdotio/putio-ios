# Design Principles

Use native platform elements with the put.io theme. Never port web component
recipes.

The adoption baseline is [`@putdotio/design` 3.3.0](https://github.com/putdotio/putio-design/releases/tag/v3.3.0),
including [Apple contract 0.2.0](https://github.com/putdotio/putio-design/blob/v3.3.0/platforms/apple/DESIGN.md).
The package, lockfile, coverage manifest, generated adapter, and provenance test
name that exact version. Its 532-token graph has no value changes from 3.0.0;
all existing generated, aliased, and excluded classifications remain valid.

The package owns colors, type scales, spacing, motion, and Phosphor icons.
Apple owns controls, layout behavior, focus, and presentation. Android follows
its own platform conventions. Roku uses shared tokens plus custom SceneGraph
conventions; web TV uses the web binding at a 10-foot scale.

## Native controls and content

- Use stock `Button`, `List`, `Form`, `Toggle`, `Picker`, `NavigationLink`,
  sheets, `ProgressView`, `Gauge`, and `ContentUnavailableView`.
- Content actions use `.borderedProminent` or `.bordered`. A button floating
  over media with no surface of its own (the video Done control) uses the
  stock glass styles through `PutioButton(presentation: .floating)`. Never put
  glass inside glass: plain glass stays neutral, at most one prominent glass
  capsule appears on a screen, and the Up Next overlay owns one glass surface
  with bordered actions.
- Set the app accent tint once. System back controls, selection, and retry
  actions inherit it. Semantic destructive and success actions retain their
  roles. App-authored text may use the generated foreground roles.
- App-authored content uses GT America through `putioFont`; control labels use
  its medium face. System tab labels, navigation titles, search fields, and
  other system-rendered chrome keep SF.
- File-type icons use yellow Phosphor assets. Native tab glyphs have an intrinsic
  24pt box; Search keeps the system glyph. Preserve raw filenames and per-glyph
  font fallback.
- Let native lists own insets, separators, row heights, and disclosure. A folder
  row is content; `NavigationLink` supplies its accessory. Rows in edit mode or
  Trash have no navigation accessory.
- Keep content backgrounds opaque and dark. Use Dynamic Type for content,
  adjacent icons, and meaningful gaps through `PutioScaledMetric`. Native
  controls own their geometry; use spacing tokens where the platform leaves
  the choice open.
- Let `AVPlayerViewController` own video transport, AirPlay, and Picture in
  Picture. App text over video uses white at fixed opacities: full white for
  headings and 78% for secondary text, following the tagged player card.
  Accent tint crosses onto video; theme-surface foreground colors do not.

## Apple ruling map

| Ruling from [putio-design#44](https://github.com/putdotio/putio-design/issues/44) | Implementation |
| --- | --- |
| Stock Gauge geometry and track | `PutioDownloadStateButton` keeps the stock intrinsic 47pt ring, approximately 7pt stroke, and tint-derived track. The 44pt target is a minimum. |
| Five download states | Idle, Queued, Downloading, Downloaded, and Failed remain distinct. Failed reuses the idle glyph and announces retry; the owning row carries its reason. |
| Native progress tracks | `ProgressView` and `Gauge` own the unfilled track; the app supplies only tint. |
| One system accent | Shell tint, secondary content actions, and stock pickers inherit `PutioTheme.Colors.accent`; authored semantic text and destructive actions keep their roles. On tvOS a secondary action keeps the system focus fill, because an accent fill under an accent label is unreadable. |
| Floating glass and content actions | `PutioButton` uses bordered content styles by default and stock glass only for the one standalone floating control. Toasts and Up Next own their floating surface; their children add no glass. |
| Brand content, system chrome | Every screen state, including sign-out failure, renders through the branded state components, so titles, descriptions, and form labels use generated brand roles. Tab/navigation/search chrome retains SF. |
| Tab glyph box | Existing intrinsic 24pt Phosphor assets remain unchanged. |
| Native folder disclosure | The shared row has no iOS/watchOS caret or disclosure flag. The gallery uses a real `NavigationLink`; live folder and move-destination links own their accessory. |

## tvOS and watchOS

Native tvOS focus belongs to `UIFocusSystem`: use stock control styles for lift,
shadow, and parallax. Do not replace focus with a custom fill-only button style.
Non-control TV surfaces retain solid token backgrounds and the `tv` type,
spacing, radius, and overscan roles. The tvOS shell is a stock `TabView`;
the device sign-in screen shows the activation code on a solid surface at
the TV heading size with tabular figures, and sign-out confirms through the
stock centered dialog. `tvOverscanPadding` tops the system safe area up to
the token overscan ratios instead of stacking on it. TV numerics use GT America tabular figures;
there is no mono face. The shared row retains a tvOS folder indicator until the
native browser in #141 owns that presentation, and a row used as a control takes
the stock `.card` style so focus lifts it rather than filling behind its fixed
brand colors.

Watch remains counts, states, and remote control, with one action per screen
and no file browser or text entry. The system owns time and navigation chrome.

The released contract also describes feature behavior that is not implemented
by this adoption. These contracts remain gates on their owning rollout issues:

| Contract | Owning issue and verdict |
| --- | --- |
| tvOS system search and suggestions | #141; deferred to the native browser/search slice |
| tvOS account values, boolean cycling, full-screen choosers | #143; preserve that issue's deliberate exclusion of playback-type settings despite the older preview card |
| tvOS custom pre-play resume overlay and native focus | #142; deferred to playback |
| Watch counts, states, and phone handoff | #154; deferred to the paired companion |
| Continue Watching discovery | #152; its post-v1 scope supersedes the older card's blanket exclusion of a discovery row |

These deferrals do not close the feature issues. The adoption preserves their
product and dependency gates.

## Verification

Run `mise run tokens`, inspect generated provenance and token-value parity, and
run `mise run verify`. Intentional component changes require recorded, inspected,
and re-asserted iOS/tvOS snapshot baselines. Use the headless gallery and affected
platform proof to inspect real native materials, focus, and Dynamic Type;
off-screen raster snapshots cannot prove Liquid Glass. Run the files-browser
journey for folder disclosure, Trash, and playback interactions.
