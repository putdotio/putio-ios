# Color Token Migration Plan

Migrate the app's colors onto the put.io design system tokens, then enable
light and dark modes. Fonts are explicitly out of scope (see Non-Goals).

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Sequencing | Two phases: tokens first (dark still forced), light mode second |
| Dark fidelity | Adopt design-system dark values faithfully; the dark theme visibly shifts once (e.g. background 20% gray → 8.5%) |
| Token flow | Vendored `Config/DesignTokens.json` + `scripts/sync-design-tokens.rb` generating colorsets + `tokens-verify` drift gate (mirrors the Phosphor icons pattern) |
| API surface | Full color token set (~76) as dual-appearance colorsets named 1:1 after design-system tokens; `UIColor.Putio` generated to match; old names deprecated in Phase 1, deleted in Phase 2 |
| Storyboards | All inline colors → named color references in Phase 1 (precondition for light mode) |
| Hardcoded Swift colors | Replace with tokens; sole exception is chrome rendered over video/media, kept literal with an exception comment |
| Appearance UX | Phase 2 ships a System / Light / Dark picker (default System) in the account area |
| Visual proof | E2e screenshot walk of main screens; Phase 2 runs it in both modes; grids attached to PRs |

## Phase 1 — on the design system, still dark

1. Vendor the design-system color tokens as `Config/DesignTokens.json`
   (a generated mirror of the canonical token build; do not hand-edit values).
2. `scripts/sync-design-tokens.rb` generates `Putio/Assets.xcassets/Colors/`
   colorsets with light (`any`) + dark appearances; `--check` mode wired into
   `make verify-fast` as the drift gate.
3. Regenerate `UIColor+Putio.swift` from the same tokens; keep the six legacy
   names as deprecated aliases mapped to their semantic roles.
4. Migrate all Swift usages and all storyboard/xib inline colors to named
   colors, mapped per role against the stable dark baseline.
5. Dark mode stays forced (`overrideUserInterfaceStyle = .dark`); the only
   intended visual change is the shift to design-system dark values.
6. Add an e2e screenshot walk capturing labeled screenshots of the main
   screens into the result bundle.

## Phase 2 — light mode ships

1. Remove the three `overrideUserInterfaceStyle = .dark` sites.
2. Add an appearance picker (System / Light / Dark, default System) with a
   persisted preference applied at launch.
3. Delete the deprecated legacy color aliases.
4. Run the screenshot walk in both modes; manual sweep of every screen in
   light mode before merge.

## Legacy → token mapping (starting point)

| Legacy | Token |
| --- | --- |
| `putio.background` | `surface.app-bg` |
| `putio.black` | `neutral.component-bg` |
| `putio.black.tint` | `surface.html-bg` |
| `putio.listSeperator` | `surface.list-item-border` |
| `putio.listSubtitle` | `neutral.text-secondary` |
| `putio.yellow` | `yellow.solid` (identical value) |

Mappings are verified against real usage during migration; deviations are
recorded here.

Recorded deviations (Phase 1):

- Nav bars use `surface.nav-bg`; selected/highlighted list rows use
  `surface.list-item-bg-active`; primary-button titles use
  `fg.primary-foreground` — refined from the coarse legacy mapping above.
- Media players keep literal black backdrops and white now-playing labels
  (over-media exception), as does the Cast expanded controller.
- Fully transparent inline colors stay literal; they are mode-independent.

Recorded deviations (Phase 2):

- `LaunchScreen.storyboard` (repo root) uses system adaptive colors
  (`systemBackground` / `systemGray5`) rather than tokens: launch screens
  have known named-color caching quirks, and the system values sit within a
  hair of `surface.app-bg` / `neutral.component-bg` in both modes.
- Known cosmetic follow-up: `yellow.solid` used as link text on light
  backgrounds (Downloads empty state) is low-contrast; consider
  `yellow.text-secondary` for text-on-background roles in a follow-up.
- The wordmark logo gained a light-appearance variant (dark ink, same yellow
  shadow) generated from the original asset; Login and LaunchScreen pick it
  up via the imageset.
- The audio player, image viewer, and PDF viewer are *not* over-media
  surfaces: their time labels, next-item label, and loading spinners use
  adaptive neutral tokens. The over-media exception is limited to the video
  player, the Cast expanded controller, and the audio poster spinner over
  the black artwork well.
- Cast chrome restyling happens in `RootContainerViewController`'s trait
  change hook, so OS-level light/dark flips under the System theme restyle
  Cast too — not just picker selections.

## Non-Goals

- Full brand typography adoption. The font *infrastructure* now exists
  (`make fonts-setup` downloads licensed faces from `static.put.io`
  into gitignored `Putio/Fonts/`; optional bundling + runtime
  registration with system-font fallback; verification builds always use
  system fonts). Applying brand type beyond navigation titles is tracked
  separately in [brand-typography.md](./brand-typography.md).
- TV/web parity work; those live in their own repositories.

## Verification

- `make verify-fast` (includes token drift gate) and full `make verify`
- `make e2e-simulator` including the screenshot walk
- Phase 2: both-mode screenshot grids + manual light sweep
- `/autoreview` closeout at the end of each phase
