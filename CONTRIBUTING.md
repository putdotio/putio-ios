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

### Brand fonts

The licensed GT America and Berkeley Mono files are never committed.
`verify`, `e2e-simulator`, and `screenshots-record` need them.
[`Config/BrandFonts.json`](Config/BrandFonts.json) pins each file's sha256;
bump a hash only with a deliberate `mise run screenshots-record`.

## Local Private Config

Signed local builds and private support integrations need
`Config/Local.xcconfig`. Ask a maintainer for an authorized iOS ciphertext file
and a machine-specific age identity, then run:

```bash
PUTIO_IOS_SOPS_FILE=/path/to/ios.sops.env mise run secrets-setup
```

- `Config/Local.xcconfig` holds secrets and team settings, never a bundle id
  override. Local builds use `io.put.dev`.
- Keep the payload contract, `Config/Local.example.xcconfig`, and the renderer
  test aligned.

## Run and validate

```bash
open Putio.xcworkspace
mise run verify-fast     # generated assets, strings, workspace sanity
mise run verify          # unit tests, unsigned simulator build
mise run e2e-simulator   # mocked XCUITests
mise run run-simulator   # signed build on a visible simulator
```

- `verify` is the gate before handoff.
- Auth, keychain, or signed-in persistence changes need both `verify` and
  `run-simulator`: only the signed build persists like a real install.
- `verify` and `e2e-simulator` each run on an ephemeral simulator.
  `PUTIO_SIMULATOR_ID=<udid>` reuses a device, but that device keeps its own
  locale, so never record baselines on it.
- Pull-request CI does not run `e2e-simulator`
  ([schedule](.github/workflows/e2e-simulator.yml)). Run it before you hand off
  SDK-backed flow changes.

### Mocked e2e

`PUTIO_E2E_MOCK_API=1` in a test's launch environment serves fixture-backed SDK
responses. The other `PUTIO_E2E_*` switches are read in
[`PutioE2EMockURLProtocol.swift`](Putio/Common/API/PutioE2EMockURLProtocol.swift)
and [`AppDelegate.swift`](Putio/AppDelegate.swift).

### Visual baselines

- After an intentional visual change, run `mise run screenshots-record` and
  commit the image diff.
- Scope a run to one screen with xcodebuild's `-only-testing:` syntax:
  `mise run screenshots-record -- --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk`.
- A scoped run skips the baseline-count tripwire. Run the full set before you
  commit an added or removed snapshot test.
- Baselines ship in a public repository. Record them only from
  `PUTIO_E2E_MOCK_API` fixtures, never a real account: no real usernames, file
  names, content ids, tokens, or local IPs.

### App Store images

- iPhone store images are the screen baselines; they need no capture.
- After a visual change that affects a store slot, run
  `mise run store-capture-ipad` and commit `PutioUITests/__Captures__/ipad-13/`.
- `mise run store-images` frames both into `screenshots/en-US/`. Commit the
  images and `Config/StoreImages.lock.json` together.

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
  `@putdotio/design/assets/*`.

To change glyphs, edit [`Config/PhosphorIcons.json`](Config/PhosphorIcons.json),
run `mise run icons-sync`, and commit the image sets with
`Config/PhosphorIcons.lock.json`.

## Measure Performance

`mise run perf` measures a large mocked account and prints each metric's median
and spread:

```bash
mise run perf                                        # 10 iterations on an ephemeral simulator
mise run perf -- --simulator <udid> --label before   # reuse one device for a before/after series
mise run perf -- --only testSelectAll,testOpenLargeImage --iterations 5
mise run perf -- --latency-ms 300                    # delay every mocked response
```

- Signposts in [`PerfSignpost.swift`](Putio/Common/Helpers/PerfSignpost.swift)
  carry counts only, never ids, names, or URLs.
- Compare numbers only from one Mac, simulator, Xcode, and day, with nothing
  else building or booted (`pgrep -fl xcodebuild`,
  `xcrun simctl list devices booted`). Simulator numbers do not transfer to
  devices.

## Configuration

- Runtime config flows from `Config/Shared.xcconfig`, the optional
  `Config/Local.xcconfig`, and `Info.plist` placeholders.
  `scripts/archive-ios.sh` passes the same `PUTIO_*` values to archive builds.
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
- Leave the checked-in `CURRENT_PROJECT_VERSION` at `1`; Release sets the
  version and build number.
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

Follow the [pull request template](.github/pull_request_template.md). Update
docs when setup, CI, or release steps change.
