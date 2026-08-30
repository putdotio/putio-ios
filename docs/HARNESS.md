# Apple Platform Harness

The repository ships a typed, headless harness for building, launching, exercising, and proving the iOS, paired watchOS, and tvOS app shells. It wraps Xcode, `simctl`, the global `putio` CLI, and `attach`; it does not replace them.

## Environment contract

A provisioned host needs Xcode 26.x, matching iOS/watchOS/tvOS Simulator runtimes, mise, and the mise-pinned Tuist version. `putio` is optional for live testing-profile checks. `attach` is optional until proof publishing.

```bash
mise install
mise run bootstrap
mise run doctor -- --output json
```

Doctor exits nonzero for missing build prerequisites and returns stable JSON with `--output json`. A shell preflight preserves actionable text or JSON failures when the selected Swift/Xcode toolchain cannot compile the harness. Optional live-lane tools produce warnings without blocking deterministic builds. Brand fonts are provisioned from the checksummed `Config/BrandFonts.json` manifest by `mise run fonts-setup` (bootstrap and CI run it) and verified inside `mise run verify`; doctor does not inspect them.

## Commands

```bash
mise run harness -- help
mise run harness -- build --platform ios
mise run harness -- boot --platform ios
mise run harness -- launch --platform watchos
mise run harness -- exercise --platform tvos
mise run harness -- screenshot --platform ios
mise run harness -- screenshot --platform ios --scenario gallery
mise run harness -- journey --platform ios --scenario files-browser
mise run harness -- record --platform watchos --record-seconds 5
mise run harness -- test --platform tvos
mise run harness -- proof --platform all
```

Platform values are `ios`, `watchos`, and `tvos`. `all` is supported by `build` and `proof`. Invalid platforms, options, run identifiers, durations, repositories, and pull-request numbers fail before invoking platform tools.

`screenshot` and `record` accept `--scenario signed-out|gallery|signed-in`. The `gallery` scenario launches the iOS or tvOS component gallery. The iOS-only `signed-in` scenario uses a deterministic in-process API, restores a session, bootstraps the account screen, and signs out after a few seconds. Other commands and unsupported platforms reject these scenarios.

`journey --platform ios --scenario files-browser` proves the browser and direct-HLS presentation with real accessibility input. One XCUITest waits for root folder `0`, taps folder `410`, opens video `411` in the system player, dismisses playback back to folder `410`, asserts its typed route contains file `411`, parent `410`, and kind `video`, then taps the native `Files` Back button and asserts the restored root. HTTP responses are deterministic fixtures; the app UI, row taps, playback-source resolution, system-player presentation, dismissal, navigation, and Back control are real. AVFoundation does not use the fixture `URLSession`, so the harness keeps the presented player visible instead of mapping that expected fixture-network failure into the app error state. This journey proves system-player handoff rather than decoded media; the runtime-proof layer owns a deterministic HLS media fixture.

`test --platform <ios|tvos>` runs snapshot suites on an ephemeral simulator via `xcodebuild test`. iOS runs the unhosted `PutioSnapshotTests` component gallery and the app-hosted `PutioFeatureTests`; tvOS runs `PutioTVSnapshotTests`. Baselines are committed under `Tests/ComponentSnapshots/__Snapshots__/<platform>/`; comparison tolerates small antialiasing drift between Simulator runtimes. Liquid Glass cannot be rasterized off-screen, so the suite renders glass surfaces with their bordered/material fallbacks (`PUTIO_SNAPSHOT_RASTER`); review the real glass appearance through the gallery captures. After an intentional visual change run `test --platform <platform> --snapshots record`, which records the baselines and re-asserts against what it wrote, then review and commit the image diff. `mise run verify` runs both platforms' suites.

All simulator commands are headless. The harness never opens Simulator.app. `boot`, `launch`, `exercise`, and capture runs create uniquely named devices and pair watchOS with an ephemeral iPhone companion. `launch`, `exercise`, and capture wait for a rendered app frame. Every created device is shut down, deleted, and verified absent on success or failure. `build` does not create devices.

`exercise` launches the selected app, relaunches it with the explicit exercised scenario, requires the fixed semantic marker in its Simulator data container, and confirms the final visible state transition while the process remains alive. The iOS exercised state uses an accessibility Dynamic Type size so proof also covers adaptive typography and content-coupled metrics. The launch scenario is shared by iOS, watchOS, and tvOS so automation never encounters custom-URL confirmation UI.

Structured failures redact inherited secret environment values, bearer credentials, token-shaped fields, and the local home-directory prefix before writing to stderr.

## Deterministic proof

`proof` regenerates the ignored workspace from the clean current commit, builds, installs, records the signed-out launch and exercised transition, verifies the app process remains alive, requires the fixed semantic exercise signal plus meaningful rendered content outside system chrome, and captures the exercised screenshot. Artifacts are written beneath:

```text
build/proof/<run-id>/<platform>/
├── app.stderr.log
├── app.stdout.log
├── launch.mp4
├── manifest.json
└── exercised.png
```

The manifest records the commit, platform, scheme, bundle identifier, runtime, device type, simulator name, fixture set, artifact sizes, and SHA-256 digests. `build/` is ignored by Git.
Proof capture rejects tracked or untracked source changes so the manifest commit always identifies the exact built source.
It pins `HEAD` before generation and requires the same revision immediately before manifest emission.

The browser journey applies the same clean-source and pinned-revision checks. It writes:

```text
build/proof/<run-id>/ios/
├── files-browser-back.png
├── files-browser-nested.png
├── files-browser-root.png
├── files-browser-test-summary.json
├── files-browser-walk.mp4
└── manifest.json
```

The journey requires exactly `1/1` passing UI test, three meaningful screenshots, and different root and nested frames. Recording is capture-gated: a raw `simctl recordVideo` stream warms while the UI test launches, the test pauses after the root browser is visible, and the harness records the capture-start timestamp before releasing the journey. The app signals capture completion after the native Back transition settles on the root. The harness retains at most three seconds of visible-root context before the capture-start timestamp, trims everything else outside the journey, and rejects a published recording longer than 25 seconds. It removes the raw recording and intermediate Xcode result bundle after extraction. Recorder warmup plus Xcode startup and teardown never enter the published walk.

Capture never uploads implicitly. Publish one reviewed artifact only after a pull request exists:

```bash
mise run harness -- publish \
  --artifact build/proof/<run-id>/ios/exercised.png \
  --repo putdotio/putio-ios \
  --pr <number>
```

## Live testing profile

Deterministic proof requires no put.io account or secret. Live smoke uses the global `putio` CLI and the dedicated `devs-fe-auto` profile:

```bash
mise run harness -- auth-status --output json
mise run harness -- live-fixture --output json
```

The live commands are fixed to the `devs-fe-auto` profile and the root `putio-ios-harness` folder; profile and namespace overrides are rejected. They remove ambient `PUTIO_CLI_TOKEN` from every child process and require authentication to resolve from the named profile before any write. `live-fixture` is idempotent: it reuses the root folder or validates the write with `--dry-run` before creating it. Tokens are never read from CLI storage or written to proof artifacts. App session injection, device-code approval, and richer live fixture creation remain unavailable until their owning CLI and app contracts land.

## CI and platform limits

Pull requests into `next` run the full repository verify gate and the same headless iOS proof command. Local review evidence must cover every affected platform. Simulator proof does not claim physical-device behavior, production signing, background execution, remote-control interaction, or Apple Watch hardware behavior.

`mise run harness-ci` uses the GitHub run identity in Actions and a unique timestamp/process identity locally, so repeated local runs preserve separate proof directories. Set `PUTIO_HARNESS_RUN_ID` only when a caller needs an explicit deterministic run identifier.
