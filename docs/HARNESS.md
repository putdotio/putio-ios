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

`journey --platform ios --scenario files-browser` proves the runnable alpha loop with real accessibility input. Sixteen unrecorded `1/1` preflights cover:

- Sign-out recovery: the existing signed-in scenario uses a one-time credential-removal failure and seeded logout failure, shows the recovery message, captures `runtime-sign-out-failure.png`, and completes sign-out after an explicit retry. Default signed-in captures keep successful sign-out behavior.
- File actions: menu-based creation and selection, context-menu rename, swipe move and Trash, delayed rollback and retry, bulk partial-failure recovery, move-picker sorting and folder creation, and a meaningful `runtime-file-actions.png` screenshot.
- Trash semantics: row context-menu actions plus Trash-enabled and permanent-delete copy from the seeded account setting.
- Trash management: list, retained-page refresh failure and retry, restore to the authoritative parent, retry after a transient permanent-delete failure, and confirmed emptying with success feedback. The empty state also supports pull-to-refresh failure and retry. Meaningful `runtime-trash-refresh-error.png`, `runtime-trash-loaded.png`, and `runtime-trash-empty.png` screenshots are retained in the proof manifest.
- Sort and continuation: the root's second page appends without a tap, the sort menu round-trips `NAME_DESC` through the server and reloads in the new order, and a meaningful `runtime-sorted-root.png` screenshot is retained.
- Search and restoration: search retries a failed second page, appends results, and opens folder and video results. Empty results support pull-to-refresh and retry. Opening the same folder in Files and Search keeps both listings current after a mutation. A relaunch restores the Files folder, native Back returns to root, and signing out clears the saved folder before the next sign-in. `runtime-search-results.png` is retained.
- Folder reconciliation: renaming a folder updates its heading in another tab; deleting it removes stale contents from that folder and its open descendant. The empty descendant stays responsive before deletion.
- History: paging past unknown events, retained-list refresh and continuation retry, folder and video navigation, missing-file recovery, failed deletion and clear retry, clear cancellation, and the account setting gate. Captures `runtime-history-loaded.png`, `runtime-history-error.png`, and `runtime-history-empty.png`.
- Deep links: cold and warm URL delivery to folder, video, History, and Account; signed-out intent replay, retained-session cold launch, lookup retry, explicit unavailable routes, and cold-link precedence over delayed saved-folder restoration with native Back ancestry. Captures `runtime-deep-link-loading.png`, `runtime-deep-link-error.png`, and `runtime-deep-link-folder.png`.
- File preferences: failed save retry, refresh-only recovery after a committed save, default sort versus folder overrides, confirmed override reset, Trash and History confirmation cancellation, Trash cleanup, live History visibility, and authoritative settings after relaunch. Captures `runtime-file-preferences.png` and `runtime-file-preferences-refresh.png`. The dedicated fixture persists server preferences in a harness-only UserDefaults namespace; other scenarios keep their defaults.
- Playback preferences: proxy-list failure and retry, failed save, refresh-only recovery after a committed save, subtitle-control visibility, and proxy/subtitle persistence across relaunch. Captures `runtime-playback-preferences.png`.
- Account rating: opening Account makes no URL-opening request; tapping the native rating link opens the fixed App Store review destination through a harness-only URL interceptor. Returning to Account does not repeat the request. `runtime-account-rating.png` captures the native entry; the journey does not open the store or submit a review.
- Audio: tapping a seeded track opens the native Now Playing sheet, plays the local fixture, pauses, changes speed, scrubs to the end, auto-advances to the folder successor, reaches end of folder, and keeps the chosen speed on reopen. Captures `runtime-audio-player.png`.
- Downloads: "Download" on the seeded root video inventories the multi-audio fixture, the picker shows English and Turkish with the storage estimate, both are selected within budget, the queue shows conversion-free progress through completion, details disclose both stored audio tracks, offline playback selects the preferred language, the position endpoint is seeded to fail so the position stays pending locally, a relaunch keeps the item and the pending position, and returning to the foreground with the endpoint restored syncs it. Removing the item reclaims storage. Captures `runtime-downloads-picker.png`, `runtime-downloads-queue.png`, and `runtime-downloads-detail.png`.
- Previews: the seeded image fails its first lookup and recovers through retry, then renders with zoom and pan; the PDF renders through PDFKit; the archive opens the unsupported explanation sheet instead of a spinner or dead row; "Open in VLC" reports the not-installed outcome with a store link, and with the harness VLC stub installed it hands the tokened stream URL off once with a return link to the folder. Captures `runtime-preview-error.png`, `runtime-preview-image.png`, `runtime-preview-document.png`, `runtime-preview-unsupported.png`, and `runtime-vlc-missing.png`.
- Resume persistence: a final playback position resolves again after reopening the video.

The recorded `1/1` XCUITest signs in through the real session transition using a deterministic OAuth callback, browses root folder `0` and folder `410`, and opens video `411`. The first MP4 conversion start fails transiently and reaches the retryable error state. Retry starts conversion, observes queued and converting states, completes, resolves the SDK-owned playback source again, and loads valid HLS through the process-local loopback server until `AVPlayerItem` reports `readyToPlay`. The test dismisses playback, returns to root with the native Back control, opens Account, and signs out.

HTTP API responses and OAuth input are deterministic fixtures. The session store, SDK conversion and playback-source resolution, app UI, AVFoundation readiness, navigation, and sign-out are real. AVFoundation uses the harness-owned loopback transport for built HLS files, not the fixture `URLSession`.

`test --platform <ios|tvos>` runs snapshot suites on an ephemeral simulator via `xcodebuild test`. iOS runs the unhosted `PutioSnapshotTests` component gallery and the app-hosted `PutioFeatureTests`; tvOS runs `PutioTVSnapshotTests`. Baselines are committed under `Tests/ComponentSnapshots/__Snapshots__/<platform>/`; comparison tolerates small antialiasing drift between Simulator runtimes. Liquid Glass cannot be rasterized off-screen, so the suite renders glass surfaces with their bordered/material fallbacks (`PUTIO_SNAPSHOT_RASTER`); review the real glass appearance through the gallery captures. After an intentional visual change run `test --platform <platform> --snapshots record`, which records the baselines and re-asserts against what it wrote, then review and commit the image diff. `mise run verify` runs both platforms' suites.

All simulator commands are headless. The harness never opens Simulator.app. `boot`, `launch`, `exercise`, and capture runs create uniquely named devices and pair watchOS with an ephemeral iPhone companion. `launch`, `exercise`, and capture wait for a rendered app frame. Every created device is shut down, deleted, and verified absent on success or failure. `build` does not create devices.

`boot --run-id <id>` names its device `putio-harness-<platform>-<id>-<8-character nonce>`, so two runs never share a name even with the same ID. Cleanup is registered before creation and targets the exact device the run created; the name is used only if a signal lands before `simctl create` returns, and that lookup is retried for about two seconds because CoreSimulatorService can finish a create whose client was already killed. The interruption check locates the owned device by that `putio-harness-ios-<id>-` prefix and preserves preexisting devices and devices created by other processes.

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
├── runtime-sign-out-failure.png
├── runtime-trash-refresh-error.png
├── runtime-trash-loaded.png
├── runtime-trash-empty.png
├── runtime-sorted-root.png
├── runtime-account-rating.png
├── runtime-audio-player.png
├── runtime-preview-error.png
├── runtime-preview-image.png
├── runtime-preview-document.png
├── runtime-preview-unsupported.png
├── runtime-vlc-missing.png
├── runtime-downloads-picker.png
├── runtime-downloads-queue.png
├── runtime-downloads-detail.png
├── runtime-playback-preferences.png
├── runtime-file-preferences.png
├── runtime-file-preferences-refresh.png
├── runtime-history-loaded.png
├── runtime-history-error.png
├── runtime-history-empty.png
├── runtime-deep-link-loading.png
├── runtime-deep-link-error.png
├── runtime-deep-link-folder.png
├── runtime-search-results.png
├── runtime-playback.png
├── runtime-sign-in.png
├── runtime-signed-out.png
├── runtime-proof-test-summary.json
├── runtime-proof-walk.mp4
└── manifest.json
```

Failed journeys retain local diagnostics, including failed `.xcresult` bundles, under the run directory. They emit no success manifest; inspect them locally and choose a new run ID for the retry. Only reviewed successful proof is published.

The journey requires each preflight and the recorded UI test to pass exactly `1/1`. It requires twenty-nine meaningful screenshots, including file actions, sign-out recovery, and all three Trash states, and different sign-in and playback frames. One `simctl recordVideo` stream starts before the recorded test and stops immediately after it exits. The harness publishes at most one second of stable initial sign-in context, re-encodes through the first stable post-sign-out frame, and requires the playback landmark between those matching endpoint screens. It rejects a recording longer than 45 seconds and removes raw/intermediate capture files after extraction. Startup, relaunch setup, and teardown outside the screenshot-matched window never enter the published walk.

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

The live commands are fixed to the `devs-auto` profile and the root `putio-ios-harness` folder; profile and namespace overrides are rejected. They remove ambient `PUTIO_CLI_TOKEN` from every child process and require authentication to resolve from the named profile before any write. `live-fixture` is idempotent: it reuses the root folder or validates the write with `--dry-run` before creating it. Tokens are never read from CLI storage or written to proof artifacts.

## CI and platform limits

[Next CI](../.github/workflows/ci-next.yml) runs `mise run verify` and `mise run harness-ci` on GitHub-hosted macOS runners for pushes to `next` and pull requests into `next`. Local review evidence must cover every affected platform. Simulator proof does not claim physical-device behavior, production signing, background execution, remote-control interaction, or Apple Watch hardware behavior.

`mise run harness-ci` uses the GitHub run identity in Actions and a unique timestamp/process identity locally, so repeated local runs preserve separate proof directories. Set `PUTIO_HARNESS_RUN_ID` only when a caller needs an explicit deterministic run identifier.
