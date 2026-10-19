# Contributing

## Setup

Most local work only needs the normal toolchain and the checked-in development defaults.

- Prerequisites:
  - Xcode `26.x`; [CI](.github/workflows/ci.yml) selects the latest stable
    release
  - iOS `26.x` simulator runtime
  - [mise](https://mise.jdx.dev) — it pins the toolchain and runs every task in
    this repo
  - [SOPS](https://getsops.io) `3.10+` and `jq` when private local config is required
  - Ruby and Node come from `mise.toml` via `mise install`; pnpm arrives with
    `corepack enable`
- Install dependencies and the pre-push hook:

```bash
mise run bootstrap
mise run fonts-setup
```

`mise run bootstrap` starts with `mise run doctor`, which checks Ruby, Node,
pnpm, and the Xcode developer directory against the repo's pins and prints a
fix for each mismatch. `mise tasks` lists every task. The pre-push hook runs
the `mise run verify-fast` gate.

Node is repo tooling only: the app builds and tests without it.

- Optional private local overrides:
  - copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`
  - keep `Config/Local.xcconfig` out of git
  - checked-in defaults already use the dedicated local dev app identity `io.put.dev`
  - `Config/Local.xcconfig` is for secrets and team settings, not bundle-id overrides

## Local Private Config

Use this path when your work needs signed local builds or private support
integrations.

- Obtain an authorized iOS ciphertext file and a machine-specific age identity
  from a maintainer
- Materialize the local config with the ciphertext path supplied explicitly:

```bash
PUTIO_IOS_SOPS_FILE=/path/to/ios.sops.env mise run secrets-setup
```

This validates the encrypted payload's exact key and value contract, then
writes ignored mode-`0600` `Config/Local.xcconfig`. SOPS discovers the age
identity from its standard location or `SOPS_AGE_KEY_FILE`. Run
`mise run secrets-clean` to remove the generated file.

### Brand fonts (required)

The licensed GT America and Berkeley Mono files are never committed;
`mise run verify-fast` fails if any font binary is tracked. They are downloaded
from `static.put.io`, the same files the web app serves, so no credentials are
needed:

```bash
mise run fonts-setup    # download into gitignored Putio/Fonts/
mise run verify-fonts   # report status without writing
```

`Config/BrandFonts.json` lists each file's path and sha256. The hash exists
because the fonts feed pixel-compared baselines: a re-uploaded font fails with
one error naming the file instead of a pile of image diffs. Bump a hash only
alongside a deliberate `mise run screenshots-record`.

Verification builds bundle the fonts (`PUTIO_BUNDLE_BRAND_FONTS = YES` in
`Config/Verify.xcconfig`), so **`mise run verify`, `mise run e2e-simulator`,
and `mise run screenshots-record` all require them.**
`PutioTests/BrandFontTests.swift` reports a missing face by name. Every CI
workflow syncs the fonts first, so every pull request, Dependabot and forks
included, gets the full snapshot suite.

- Local signed builds default to:
  - bundle id `io.put.dev`
  - display name `put.io`
  - primary icon `AppIconDev` (blueprint)
- TestFlight uses `AppIconNightly`; App Store uses `AppIcon`
- Keep the encrypted payload contract, `Config/Local.example.xcconfig`, and the
  renderer test aligned
- CI beta and release builds use the release-secret contract in [Distribution](./docs/distribution.md)

## Run And Validate

- Open the workspace in Xcode:

```bash
open Putio.xcworkspace
```

- Quick local path:

```bash
mise run verify-fast
mise run verify
mise run e2e-simulator
mise run run-simulator
```

- Useful helpers:

```bash
mise run doctor
mise run print-simulator-destination
mise run print-simulator-device
mise run download-ios-platform
mise run verify-icons
mise run dead-code   # Periphery scan; builds the app, so it stays out of CI
plutil -lint Putio/en.lproj/*.strings
```

- Notes:
  - `mise run verify` uses an unsigned simulator build; `mise run run-simulator` uses a signed one so auth and keychain persistence behave like a real run. When auth, keychain, or signed-in persistence changes, use both
  - `mise run verify` and `mise run e2e-simulator` each create an ephemeral simulator (pinned status bar and `en_US` locale) and delete it on exit, so parallel worktrees never collide. They write `build/verify.xcresult` and `build/e2e-simulator.xcresult`; CI uploads the verify bundle when a run fails. `PUTIO_SIMULATOR_ID=<udid>` reuses a specific device, but it keeps its own locale, so record baselines on the ephemeral one
  - the simulator is pinned to **iPhone 17 Pro Max** on iOS `26.0+` (`scripts/simctl-iphone-device-id.sh`) so baseline dimensions don't depend on which simulators a machine has
  - `E2E Simulator` runs against `main` every Monday at 06:00 UTC and on dispatch (`gh workflow run e2e-simulator.yml --ref main`), never on pull requests. Run `mise run e2e-simulator` before handing off PRs or SDK-backed flow changes
  - `mise run verify-scripts-types` type-checks the repo's TypeScript tooling with `tsc --noEmit`; Node runs the scripts without a build step, and stripping types is not checking them. CI runs it in the `verify-tooling` job

### Mocked e2e

`mise run e2e-simulator` runs mocked XCUITests against fixture-backed SDK
responses. Set these in a test's launch environment:

- `PUTIO_E2E_MOCK_API=1` enables the mock
- `PUTIO_E2E_FAIL_ROUTES` (comma-separated `METHOD /path` keys) forces 500 responses; `PUTIO_E2E_OFFLINE_ROUTES` (same format) fails them with a no-connection error
- `PUTIO_E2E_UPGRADING_FROM_258=1` with `PUTIO_E2E_RESET_STATE=1` starts as the first launch after the update from 2.58.0
- `PUTIO_E2E_ACCOUNT=inactive` answers `/account/info` as a deactivated account whose files go in 14 days
- `PUTIO_E2E_PRODUCT_ANALYTICS_UNANSWERED=1` serves a config that has not answered the product-analytics prompt; the default has

Under `PUTIO_E2E_MOCK_API=1` the app also holds back behavior a screenshot
cannot capture deterministically: the downloads tutorial parks its clip on a
fixed frame, the files nav bar omits the Google Cast button (it depends on
receivers on the LAN), and the login screen does not auto-start web auth.
Tapping `Log in` still starts the flow.

### Visual baselines

- Components render in unit tests into `PutioTests/__Snapshots__/`; full screens come from the e2e walk into `PutioUITests/__Snapshots__/`. The app is dark-only, so baselines are dark mode only
- After an intentional visual change, run `mise run screenshots-record` and commit the image diff. It records and then asserts against what it wrote, so a green exit needs no second run
- Scope it when you changed one screen: `mise run screenshots-record -- --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk` takes about a minute against about five for the full set. `--only` takes xcodebuild's `-only-testing:` syntax and its leading test target picks the tier. `mise run screenshots-record-components` and `mise run screenshots-record-screens` run one whole tier
- A scoped run skips the baseline-count tripwire; run the full target before committing if you added or removed a snapshot test
- `mise run vref` renders a local gallery of the baselines for design review, and `mise run vref-serve` serves it; see [.vref/README.md](./.vref/README.md)

### App Store images

- `mise run store-screenshots` writes the App Store set to gitignored `dist/store-screenshots/<device>/` in display order; `mise run verify-store-screenshots` validates without writing. Slot order lives in `Config/StoreScreenshots.json`
- **iPhone** needs no capture: the pinned simulator's 1320x2868 walk output is Apple's 6.9" size, so the store images are the baselines CI compares
- **iPad** has no asserted walk. `mise run store-capture-ipad` (about 2 minutes) runs the walk on an ephemeral iPad Pro 13-inch (M5) and writes 2064x2752 images to `PutioUITests/__Captures__/ipad-13/`, committed so `store-screenshots` needs no capture. Run it after a visual change that affects a store slot
- `mise run store-images` frames both into `screenshots/en-US/` with captions from `Config/StoreCaptions.json`. Commit the images and `Config/StoreImages.lock.json` together
- `mise run verify-store-images` hashes the inputs against that lock instead of re-rendering, so CI runs it on Linux. Keys starting with `$` are excluded from the hashes

## Targeted Regression Checks

- Focused xcodebuild runs are fine while iterating, but treat `mise run verify` as the repo gate before handoff
- Useful targeted suites:
  - `PutioTests/APIErrorLocalizerTests`
  - `PutioTests/ErrorPresentationTests`
  - `PutioTests/NavigationLocalizationTests`
  - `PutioTests/PutioRealmTests`

## Measure Performance

`mise run perf` runs `PutioUITests/PerformanceUITests` against a large mocked account and prints each metric's median and spread over N iterations:

```bash
mise run perf                                        # N=10 on an ephemeral simulator
mise run perf -- --simulator <udid> --label before   # reuse one device for a before/after series
mise run perf -- --only testSelectAll,testOpenLargeImage --iterations 5
mise run perf -- --latency-ms 300                    # delay every mocked response
```

- It builds `PutioE2E` in Debug, so the mocked API stays compiled in, with release optimization (`-O`, whole module, no testability) into `build/perf/DerivedData`, leaving verify's build alone. Results land in `build/perf/<label>.xcresult` and `build/perf/<label>.json`. The tests skip unless `PUTIO_PERF=1`, so `mise run e2e-simulator` only lists them
- `PUTIO_E2E_FIXTURE=large` serves a deterministic account in place of the walk's fixture: 2,000 root items (40 folders, 1,000 videos, 300 audio, 400 images, 200 PDFs, 60 other), a 12-level folder chain of 200 items each, 500 seeded downloads, and generated 48 MP JPEG and 300-page PDF previews. `/files/list` answers by `parent_id`, and the mock also serves `MediaPreviewSession`, which previews load through. `PUTIO_E2E_LATENCY_MS` delays every mocked response. Unset, both leave the default fixture and its baselines untouched
- The tests cover cold launch, launch to the first file rows, root scroll (duration, CPU, memory, and hitches on a device; the simulator reports none), image and PDF open, Select All, and the `FilesViewController`s still alive and `/files/list` requests fired after pushing five folders, popping back, and foregrounding. The large fixture installs a 1pt `putio-perf-probe` accessibility element the tests read those counts from
- Debug builds mark `io.put.perf` Points of Interest intervals: `LaunchToFiles`, `FetchUser`, `FilesFetch`, `FilesReload`, `SelectAll`, `ImageOpen`, `PDFOpen`. They carry row counts only, never ids, names, or URLs. The intervals that end on screen commit the pending frame first, so layout, drawing, and image decoding count. Release compiles the intervals and that early commit out
- Compare numbers only from one Mac, simulator, Xcode, and day, with nothing else building or booted: check `pgrep -fl xcodebuild` and `xcrun simctl list devices booted` first. The mocked launch skips download restore and Cast, so it undercounts production work, and simulator numbers do not transfer to devices

## Configuration

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- `scripts/archive-ios.sh` passes the same `PUTIO_*` values to Xcode during beta and release archive builds
- User-facing copy has an English base under `Putio/en.lproj`
  - when changing copy in Swift, update `Putio/en.lproj/Localizable.strings`
  - when changing storyboard or xib copy, update the matching `Putio/en.lproj/*.strings` file
- Product UI glyphs use the pinned Phosphor asset workflow in [Icon system](./docs/icons.md)
- Keep repo-stored configuration open-source-safe
  - keep tokens, signing keys, API key files, and private release metadata out of commits

## CI And Delivery

[Distribution](./docs/distribution.md) covers workflow roles, CI bootstrap, the
asc delivery contract, and TestFlight and App Store Connect notes.

Listing work needs the pinned [asc](https://asccli.sh) CLI. Install it and turn
its telemetry off once, then check the listing offline:

```sh
./scripts/install-asc.sh   # asc 5.15.0 into ~/.local/bin, checksum-verified
asc telemetry disable
node scripts/app-store.ts check
```

## Good First Contributions

- Add focused unit coverage around pure logic and model parsing
- Shrink UIKit and storyboard hotspots, such as Files and Settings, without changing behavior
- Locales beyond English, and copy consistency, in isolated pull requests

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
