# Contributing

## Setup

Prerequisites:

- Xcode `27.x` and the iOS `27.x` simulator runtime: `verify`, `e2e-simulator`,
  and the visual baselines run on iOS 27
- [mise](https://mise.jdx.dev): it pins the toolchain and runs every task
  (`mise tasks` lists them)
- Toolchain binaries pinned in [`mise.toml`](mise.toml) via `mise install`
- pnpm via its [installer](https://pnpm.io/installation) (avoid Corepack); pnpm
  switches to the `package.json` `packageManager` pin on first use

Install the toolchain, dependencies, pre-push hook, and brand fonts:

```bash
mise install
mise run bootstrap
mise run fonts-setup
```

### Brand fonts

`verify`, `e2e-simulator`, and `screenshots-record` require the local fonts
downloaded by `mise run fonts-setup` (pinned in
[`Config/BrandFonts.json`](Config/BrandFonts.json)). Never commit font files;
bump a sha256 only alongside `mise run screenshots-record`.

## Local Private Config

Signed local builds, OAuth sign-in and Cast need `Config/Local.xcconfig`. Copy
[`Config/Local.example.xcconfig`](Config/Local.example.xcconfig) and set your
team and any local service overrides (defaults live in
[`Config/Shared.xcconfig`](Config/Shared.xcconfig)):

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

- `Config/Local.xcconfig` holds secrets and team settings, never a bundle id
  override. Local builds use `io.put.dev`.
- Keep `Config/Local.xcconfig` out of git and remove it before removing a
  worktree.

## Run and validate

```bash
open Putio.xcworkspace
mise run verify-fast         # generated assets, import and font guards, strings, workspace sanity
mise run verify              # verify-fast, SwiftLint, unit and component snapshot tests, acknowledgements
mise run e2e-simulator       # mocked XCUITests (skips screenshot walk and perf)
mise run screenshots-verify  # screenshot walk against the screen baselines
mise run run-simulator       # signed build on a visible simulator
```

- `verify` is the gate before handoff; [Verification](AGENTS.md#verification)
  maps each kind of change to the checks it adds.
- Only the signed `run-simulator` build persists auth and keychain state like
  a real install.
- `verify`, `e2e-simulator`, `screenshots-verify`, and `screenshots-record`
  each run on an ephemeral simulator. `PUTIO_SIMULATOR_ID=<udid>` reuses a
  device, which keeps its own locale.
- No CI runs the full `e2e-simulator` suite; the
  [weekly smoke](.github/workflows/e2e-simulator.yml) runs a few of its tests.

### Mocked e2e

`PUTIO_E2E_MOCK_API=1` in a test's launch environment serves fixture-backed SDK
responses. The other `PUTIO_E2E_*` switches are read in
[`PutioE2EMockURLProtocol.swift`](Putio/Common/API/PutioE2EMockURLProtocol.swift),
[`PutioE2EEnvironment.swift`](Putio/Common/API/PutioE2EEnvironment.swift),
[`PutioE2ELargeFixture.swift`](Putio/Common/API/PutioE2ELargeFixture.swift),
and [`AppDelegate.swift`](Putio/AppDelegate.swift). Mocked runs disable UIKit
animations unless the test sets `PUTIO_E2E_ANIMATIONS=1`, as the screenshot
walk does.

### Visual baselines

- After an intentional visual change, run `mise run screenshots-record` on
  the ephemeral simulator it creates, and commit the image diff.
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
- Scale icons with UIKit constraints.
- The filled yellow folder stays the file-browser signature icon.
- Save-to-put.io, download-to-device, and stream or play stay distinct metaphors.
- Brand artwork, app icons, media artwork, and other non-glyph images stay
  outside Phosphor.
- The `AppIcon*` catalogs take their 1024×1024 marks from
  `@putdotio/design/assets/*`, copied manually into
  `Putio/Assets.xcassets/AppIcon*.appiconset`.

To change glyphs, edit [`Config/PhosphorIcons.json`](Config/PhosphorIcons.json),
run `mise run icons-sync`, and commit the image sets with
`Config/PhosphorIcons.lock.json`.

## Measure Performance

Profile the affected flow before and after on one physical device, with
Instruments and an optimized build. Signposts in
[`PerfSignpost.swift`](Putio/Common/Helpers/PerfSignpost.swift) log to Points
of Interest with counts only.

`mise run perf` gives early simulator feedback on a large mocked account:
launch to files, and opening a large image and PDF.

```bash
mise run perf                                   # 3 iterations on an ephemeral simulator
mise run perf -- --only testOpenLargePDF --iterations 5
mise run perf -- --latency-ms 300               # delay every mocked response
```

Simulator numbers don't transfer to devices. After release, check Sentry or the
Xcode Organizer.

## Configuration

- Runtime config flows from [`Config/`](Config) (`Shared`, `Debug`, `Release`,
  `Verify`, and optional `Local.xcconfig`) into [`Putio/Info.plist`](Putio/Info.plist).
  [`scripts/archive-ios.sh`](scripts/archive-ios.sh) overrides the archive
  `PUTIO_*` build settings in CI.
- Keep tokens, signing keys, API key files, and private release metadata out of
  commits.

## CI and delivery

The [workflows](.github/workflows) own CI, TestFlight, and App Store delivery.
Maintainers keep secret rotation and App Privacy answers outside this
repository.

- The App Store listing is code: `metadata/`, `screenshots/`, and
  [`Config/AppStore.json`](Config/AppStore.json). Never edit those fields in
  App Store Connect; only the App Review contact lives there.
- Release timing and phased rollout live in [`Config/AppStore.json`](Config/AppStore.json);
  pause or halt an active rollout in App Store Connect.
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
