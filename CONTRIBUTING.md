# Contributing

## Setup

Prerequisites:

- Xcode `26.x` and the iOS `26.x` simulator runtime
- [mise](https://mise.jdx.dev): it pins the toolchain and runs every task
  (`mise tasks` lists them)
- Ruby and Node from `mise install`; pnpm from `corepack enable`
- [SOPS](https://getsops.io) `3.10+` and `jq`, only for
  [private local config](#local-private-config)

Install dependencies, the pre-push hook, and the brand fonts:

```bash
mise run bootstrap
mise run fonts-setup
```

`bootstrap` starts with `mise run doctor`, which checks the toolchain against
the pins and prints a fix for each mismatch. The pre-push hook runs
`mise run verify-fast`. Node is repo tooling only; the app builds without it.

### Brand fonts

The licensed GT America and Berkeley Mono files are never committed;
`verify-fast` fails if a font binary is tracked. `mise run fonts-setup`
downloads them from `static.put.io` into the ignored `Putio/Fonts/`, and
`mise run verify-fonts` reports their status without writing.

Verification builds bundle the fonts (`Config/Verify.xcconfig`), so `verify`,
`e2e-simulator`, and `screenshots-record` need them.
[`Config/BrandFonts.json`](Config/BrandFonts.json) pins each file's sha256, so a
re-uploaded font fails with one named error instead of a pile of image diffs.
Bump a hash only with a deliberate `mise run screenshots-record`.

## Local Private Config

Signed local builds and private support integrations need
`Config/Local.xcconfig`. Ask a maintainer for an authorized iOS ciphertext file
and a machine-specific age identity, then run:

```bash
PUTIO_IOS_SOPS_FILE=/path/to/ios.sops.env mise run secrets-setup
```

It validates the payload's key and value contract and writes the ignored
`Config/Local.xcconfig` with mode `0600`. SOPS finds the age identity in its
standard location or `SOPS_AGE_KEY_FILE`. `mise run secrets-clean` removes the
file.

- `Config/Local.xcconfig` holds secrets and team settings, never a bundle id
  override. Local builds use `io.put.dev`.
- Keep the payload contract, `Config/Local.example.xcconfig`, and the renderer
  test aligned.
- CI reads the GitHub `release` Environment instead;
  [load-ios-release-secrets](.github/actions/load-ios-release-secrets/action.yml)
  validates its keys.

## Run and validate

```bash
open Putio.xcworkspace
mise run verify-fast     # generated assets, strings, workspace sanity
mise run verify          # unit tests, unsigned simulator build
mise run e2e-simulator   # mocked XCUITests
mise run run-simulator   # signed build on a visible simulator
```

- `verify` is the gate before handoff; focused `xcodebuild` runs are fine while
  iterating.
- Auth, keychain, or signed-in persistence changes need both `verify` and
  `run-simulator`: only the signed build persists like a real install.
- `verify` and `e2e-simulator` each create an ephemeral iPhone 17 Pro Max
  simulator with a pinned status bar and `en_US` locale, then delete it, so
  parallel worktrees never collide. `PUTIO_SIMULATOR_ID=<udid>` reuses a
  device, but that device keeps its own locale, so never record baselines on it.
- Pull-request CI does not run `e2e-simulator`
  ([schedule](.github/workflows/e2e-simulator.yml)). Run it before you hand off
  SDK-backed flow changes.
- `mise run dead-code` runs a Periphery scan. It builds the app, so CI skips it.

### Mocked e2e

`PUTIO_E2E_MOCK_API=1` in a test's launch environment serves fixture-backed SDK
responses. The other `PUTIO_E2E_*` switches (failed or offline routes, account
states, upgrade path, fixture size, latency) are read in
[`PutioE2EMockURLProtocol.swift`](Putio/Common/API/PutioE2EMockURLProtocol.swift)
and [`AppDelegate.swift`](Putio/AppDelegate.swift).

Under the mock, the app holds back behavior a screenshot can't capture
deterministically: the downloads tutorial parks its clip on a fixed frame, the
files nav bar omits the Cast button, and login does not auto-start web auth.

### Visual baselines

- Components render in unit tests into `PutioTests/__Snapshots__/`; full
  screens come from the e2e walk into `PutioUITests/__Snapshots__/`. The app is
  dark-only, so baselines are too.
- After an intentional visual change, run `mise run screenshots-record` and
  commit the image diff. It records, then asserts against what it wrote.
- Scope a run to one screen with xcodebuild's `-only-testing:` syntax; the
  leading test target picks the tier:
  `mise run screenshots-record -- --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk`.
  `screenshots-record-components` and `screenshots-record-screens` run one tier.
- A scoped run skips the baseline-count tripwire. Run the full set before you
  commit an added or removed snapshot test.
- `mise run vref` builds a local gallery of the baselines for design review
  ([.vref/README.md](.vref/README.md)).

### App Store images

- `mise run store-screenshots` writes the App Store set to the ignored
  `dist/store-screenshots/<device>/`; slot order lives in
  [`Config/StoreScreenshots.json`](Config/StoreScreenshots.json).
- iPhone needs no capture: the pinned simulator's walk output is Apple's 6.9"
  size, so the store images are the baselines CI compares.
- iPad has no asserted walk. After a visual change that affects a store slot,
  run `mise run store-capture-ipad` and commit `PutioUITests/__Captures__/ipad-13/`.
- `mise run store-images` frames both into `screenshots/en-US/` with captions
  from `Config/StoreCaptions.json`. Commit the images and
  `Config/StoreImages.lock.json` together; CI checks the lock with
  `mise run verify-store-images`.

## Icons

Product glyphs are [Phosphor Icons](https://github.com/phosphor-icons/core),
like the put.io design system, checked into `Putio/Assets.xcassets/Phosphor`.

- Regular weight in neutral gray by default; fill weight for selected or active
  states.
- Keep the SVG canvas at 16 points; scale it with UIKit constraints.
- The filled yellow folder stays the file-browser signature icon.
- Save-to-put.io, download-to-device, and stream/play stay distinct metaphors.
- Brand artwork, app icons, media artwork, and other non-glyph images stay
  outside Phosphor.
- The `AppIcon*` catalogs take their 1024×1024 marks from
  `@putdotio/design/assets/*`; the workflows pick one per channel.

To change glyphs, edit the list in
[`Config/PhosphorIcons.json`](Config/PhosphorIcons.json), run
`mise run icons-sync`, review the image sets and `Config/PhosphorIcons.lock.json`
diff, then run `mise run verify`. `mise run verify-icons`, part of
`verify-fast`, fails on drift from the manifest and on SF Symbol call sites.

## Measure Performance

`mise run perf` runs `PutioUITests/PerformanceUITests` against a large mocked
account and prints each metric's median and spread:

```bash
mise run perf                                        # 10 iterations on an ephemeral simulator
mise run perf -- --simulator <udid> --label before   # reuse one device for a before/after series
mise run perf -- --only testSelectAll,testOpenLargeImage --iterations 5
mise run perf -- --latency-ms 300                    # delay every mocked response
```

- It builds `PutioE2E` with release optimization into `build/perf/`, apart from
  verify's build, and writes `build/perf/<label>.xcresult` and `.json`.
- The tests skip unless `PUTIO_PERF=1`, so `e2e-simulator` only lists them.
- The fixture lives in
  [`PutioE2ELargeFixture.swift`](Putio/Common/API/PutioE2ELargeFixture.swift);
  Debug builds mark `io.put.perf` Points of Interest from
  [`PerfSignpost.swift`](Putio/Common/Helpers/PerfSignpost.swift). Signposts
  carry counts only, never ids, names, or URLs.
- Compare numbers only from one Mac, simulator, Xcode, and day, with nothing
  else building or booted (`pgrep -fl xcodebuild`,
  `xcrun simctl list devices booted`). The mocked launch skips download restore
  and Cast, and simulator numbers do not transfer to devices.

## Configuration

- Runtime config flows from `Config/Shared.xcconfig`, the optional
  `Config/Local.xcconfig`, and `Info.plist` placeholders.
  `scripts/archive-ios.sh` passes the same `PUTIO_*` values to archive builds.
- Private support integrations are off by default in `Putio/Info.plist`.
- Copy changes in Swift go in `Putio/en.lproj/Localizable.strings`; storyboard
  and xib copy goes in the matching `Putio/en.lproj/*.strings` file.
- Keep tokens, signing keys, API key files, and private release metadata out of
  commits.

## CI and delivery

The [workflows](.github/workflows) own CI, TestFlight, and App Store delivery.
The release runbook, App Privacy answers, and secret rotation live in
[iOS release](https://app.notion.com/p/3fdd546ba2f581a29718c0deeac09e20) in the
put.io Notion.

- The App Store listing is code: `metadata/`, `screenshots/`, and
  [`Config/AppStore.json`](Config/AppStore.json). Never edit those fields in
  App Store Connect; only the App Review contact lives there.
- Each release needs `metadata/version/<version>/en-US.json` before Release
  runs. A field left out of `metadata/` stays unmanaged; to adopt one, copy it
  from the Screenshots dry run's artifact.
- Release sets the version and build number. Leave the checked-in
  `CURRENT_PROJECT_VERSION` at `1`.
- Change [`Putio/PrivacyInfo.xcprivacy`](Putio/PrivacyInfo.xcprivacy) and the
  App Privacy answers together.

Listing work needs the pinned [asc](https://asccli.sh) CLI with its telemetry
off:

```sh
./scripts/install-asc.sh   # checksum-verified, into ~/.local/bin
asc telemetry disable
node scripts/app-store.ts check
```

## Good first contributions

- Unit coverage for pure logic and model parsing
- Smaller UIKit and storyboard hotspots, such as Files and Settings, with no
  behavior change
- New locales and copy consistency, each in its own pull request

## Pull requests

The [pull request template](.github/pull_request_template.md) holds the review
checklist. Keep each pull request to one change, add verification when
behavior changes, and update docs when setup, CI, or release steps change.
