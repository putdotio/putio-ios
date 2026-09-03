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

`journey --platform ios --scenario files-browser` proves the runnable alpha loop with real accessibility input. Five unrecorded `1/1` preflights cover:

- File actions: create, optimistic rename, delayed rollback and retry, move, bulk partial-failure recovery, and a meaningful `runtime-file-actions.png` screenshot.
- Trash semantics: visible per-row actions plus Trash-enabled and permanent-delete copy from the seeded account setting.
- Trash management: list, restore to the authoritative parent, retry after a transient permanent-delete failure, confirmed emptying, and a meaningful `runtime-trash-loaded.png` screenshot.
- Unsupported files: the PDF row remains visible but is not actionable.
- Resume persistence: a final playback position resolves again after reopening the video.

The recorded `1/1` XCUITest signs in through the real session transition using a deterministic OAuth callback, terminates and relaunches the app to prove Keychain restoration, browses root folder `0` and folder `410`, and opens video `411`. The first MP4 conversion start fails transiently and reaches the retryable error state. Retry starts conversion, observes queued and converting states, completes, resolves the SDK-owned playback source again, and loads valid HLS through the process-local loopback server until `AVPlayerItem` reports `readyToPlay`. The test dismisses playback, returns to root with the native Back control, opens Account, and signs out.

HTTP API responses and OAuth input are deterministic fixtures. The session store, SDK conversion and playback-source resolution, app UI, AVFoundation readiness, navigation, and sign-out are real. AVFoundation uses the harness-owned loopback transport for built HLS files, not the fixture `URLSession`.

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

The runtime-proof journey applies the same clean-source and pinned-revision checks. It writes:

```text
build/proof/<run-id>/ios/
├── runtime-file-actions.png
├── runtime-playback.png
├── runtime-sign-in.png
├── runtime-signed-out.png
├── runtime-proof-test-summary.json
├── runtime-proof-walk.mp4
└── manifest.json
```

The journey requires each preflight and the recorded UI test to pass exactly `1/1`. It requires four meaningful screenshots, including the file-actions proof, and different sign-in and playback frames. One `simctl recordVideo` stream starts before the recorded test and stops immediately after it exits. The harness publishes at most one second of stable initial sign-in context, re-encodes through the first stable post-sign-out frame, and requires the playback landmark between those matching endpoint screens. It rejects a recording longer than 30 seconds and removes raw/intermediate capture files after extraction. Startup, relaunch setup, and teardown outside the screenshot-matched window never enter the published walk.

Capture never uploads implicitly. Publish one reviewed artifact only after a pull request exists:

```bash
mise run harness -- publish \
  --artifact build/proof/<run-id>/ios/exercised.png \
  --repo putdotio/putio-ios \
  --pr <number>
```

## Live testing profile

Deterministic proof requires no put.io account or secret. Live smoke uses the global `putio` CLI and the dedicated `devs-auto` profile:

```bash
mise run harness -- auth-status --output json
mise run harness -- live-fixture --output json
```

The live commands are fixed to the `devs-auto` profile and the root `putio-ios-harness` folder; profile and namespace overrides are rejected. They remove ambient `PUTIO_CLI_TOKEN` from every child process and require authentication to resolve from the named profile before any write. `live-fixture` is idempotent: it reuses the root folder or validates the write with `--dry-run` before creating it. Tokens are never read from CLI storage or written to proof artifacts. App session injection, device-code approval, and richer live fixture creation remain unavailable until their owning CLI and app contracts land.

## CI and platform limits

Pull requests into `next` run the full repository verify gate and the same headless iOS proof command. Local review evidence must cover every affected platform. Simulator proof does not claim physical-device behavior, production signing, background execution, remote-control interaction, or Apple Watch hardware behavior.

`mise run harness-ci` uses the GitHub run identity in Actions and a unique timestamp/process identity locally, so repeated local runs preserve separate proof directories. Set `PUTIO_HARNESS_RUN_ID` only when a caller needs an explicit deterministic run identifier.
