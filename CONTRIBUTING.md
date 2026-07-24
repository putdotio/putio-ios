# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Most local work only needs the normal toolchain and the checked-in development defaults.

- Prerequisites:
  - Xcode `26.x`
  - iOS `26.x` simulator runtime
  - Ruby from `.ruby-version`
- Install dependencies:

```bash
make bootstrap
```

`make bootstrap` starts with a `make doctor` preflight that checks your active
Ruby against `.ruby-version` and your Xcode developer directory, printing
copy-pasteable fixes when either is wrong. It also installs the repo pre-push
hook (`.githooks/pre-push` via `core.hooksPath`), which runs the sub-second
`make verify-fast` gate before every push.

- Optional private local overrides:
  - copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`
  - keep `Config/Local.xcconfig` out of git
  - checked-in defaults already use the dedicated local dev app identity `io.put.dev`
  - `Config/Local.xcconfig` is for secrets and team settings, not bundle-id overrides

## Local Private Config

Use this path when your work needs signed local builds or private support
integrations.

- Sign in to Infisical and make sure workspace onboarding has granted access to the `frontend` project and Development environment
- Materialize the local config:

```bash
make secrets-setup
```

This renders `Config/Local.xcconfig` from the repo-owned Infisical path. Set
the onboarding-provided `PUTIO_IOS_INFISICAL_*` variables in this repo or
worktree shell before running the command. Run `make secrets-clean` to remove
the generated file.

### Brand fonts (optional, maintainers)

The licensed GT America families are never committed. Sync them from the
private putio-static repository (requires `gh auth login` with access):

```bash
make fonts-setup   # sync into gitignored Putio/Fonts/
make fonts-check   # report presence without writing
```

`Config/BrandFonts.json` pins the source commit and per-file checksums;
`make fonts-check` fails only when the directory contradicts the manifest
(stale checksum or unlisted font file) — absent fonts are the accepted
optional state for local work. When fonts are present they are bundled into
normal builds and registered at launch; when absent every surface falls
back to system fonts. CI beta and release archives sync them with a
`putio-release-bot` installation token (downscoped to read-only Contents
on `putdotio/putio-static`) and fail loudly if the sync cannot run, so
TestFlight and App Store builds always ship brand typography (see
[Distribution](./docs/DISTRIBUTION.md)).

Verification builds never bundle fonts (`PUTIO_BUNDLE_BRAND_FONTS = NO` in
`Config/Verify.xcconfig`), so snapshot baselines are always recorded and
compared on system fonts. That exclusion is applied via `-xcconfig` in the
make targets, not in the Xcode project — record baselines through
`make screenshots-record`, never from Xcode directly with fonts synced
(the BrandFontTests suite fails loudly in that configuration as a guard).

- Local signed builds default to:
  - bundle id `io.put.dev`
  - display name `put.io`
  - primary icon `AppIconDev`
- Keep the repo-owned Infisical path aligned with `Config/Local.example.xcconfig`
- CI beta and release builds use the release-secret contract in [Distribution](./docs/DISTRIBUTION.md)

## Run And Validate

- Open the workspace in Xcode:

```bash
open Putio.xcworkspace
```

- Quick local path:

```bash
make verify-fast
make verify
make e2e-simulator
make run-simulator
```

- Useful helpers:

```bash
make doctor
make print-simulator-destination
make print-simulator-device
make download-ios-platform
make icons-verify
plutil -lint Putio/en.lproj/*.strings
```

- Notes:
  - `make verify-fast` is the sub-second gate (icon sync check, strings lint, workspace sanity); the pre-push hook runs it automatically
  - visual baselines cover reusable components (`PutioTests/__Snapshots__/`, rendered directly in unit tests) and 12 full screens (`PutioUITests/__Snapshots__/`, captured by the e2e walk); the app is dark-only, so baselines capture dark mode only; after an intentional visual change run `make screenshots-record` and commit the resulting image diff (GitHub renders before/after in review)
  - `make verify` uses an unsigned simulator build
  - `make verify` and `make e2e-simulator` write result bundles to `build/verify.xcresult` and `build/e2e-simulator.xcresult`; CI uploads them as artifacts when a run fails
  - `make e2e-simulator` runs fast mocked XCUITests against fixture-backed SDK responses; set `PUTIO_E2E_MOCK_API=1` plus `PUTIO_E2E_FAIL_ROUTES` (comma-separated `METHOD /path` keys) in a test's launch environment to force 500 responses for failure-path coverage
  - `make verify` and `make e2e-simulator` each create an ephemeral simulator and delete it on exit, so parallel worktrees and agents never collide; set `PUTIO_SIMULATOR_ID=<udid>` to reuse a specific device instead
  - GitHub Actions exposes `E2E Simulator` as a manual workflow for PRs or SDK-backed flow changes that need simulator confidence, and runs it weekly against `main` (Mondays 06:00 UTC)
  - `make run-simulator` uses a normal signed Simulator build so auth and keychain persistence behave like a real interactive run
  - any iPhone simulator on iOS `26.0+` is fine
  - when auth, keychain, or signed-in persistence changes, use both `make verify` and `make run-simulator`

## Targeted Regression Checks

- Focused xcodebuild runs are fine while iterating, but treat `make verify` as the repo gate before handoff
- Useful targeted suites after recent cleanup work:
  - `PutioTests/APIErrorLocalizerTests`
  - `PutioTests/ErrorPresentationTests`
  - `PutioTests/NavigationLocalizationTests`
  - `PutioTests/PutioRealmTests`

## Configuration

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- Fastlane passes the same `PUTIO_*` values through Xcode during beta archive builds
- User-facing copy now has an English base under `Putio/en.lproj`
  - when changing copy in Swift, update `Putio/en.lproj/Localizable.strings`
  - when changing storyboard or xib copy, update the matching `Putio/en.lproj/*.strings` file
- Product UI glyphs use the pinned Phosphor asset workflow in [Icon system](./docs/ICONS.md)
  - edit `Config/PhosphorIcons.json` and run `make icons-sync` when adding or updating icons
  - do not hand-edit generated files under `Putio/Assets.xcassets/Phosphor`
- Keep repo-stored configuration open-source-safe
  - keep tokens, signing keys, API key files, and private release metadata out of commits

## CI And Delivery

- See [Distribution](./docs/DISTRIBUTION.md) for:
  - workflow roles
  - CI bootstrap behavior
  - fastlane release contract
  - TestFlight distribution notes
  - signing and App Store Connect gotchas

## Known Debt

- The app is still a legacy UIKit and storyboard codebase
- Some large feature areas, especially Files and Settings, have been split into smaller units but still carry historical complexity
- English localization is extracted, but additional locale coverage is still follow-up work

## Good First Contributions

- Add focused unit coverage around pure logic and model parsing
- Continue shrinking legacy UIKit hotspots without changing behavior
- Improve light mode and visual polish without changing release infrastructure
- Tackle localization and copy consistency in isolated follow-up pull requests

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Include the most helpful review evidence for the kind of change you made
  - screenshots or screen recordings for UI, layout, animation, onboarding, or copy changes
  - sanity checks for risky or user-visible flows
  - before and after benchmark numbers for performance-sensitive changes
  - risk, rollout, or follow-up notes when touching auth, persistence, release flow, or external integrations
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
