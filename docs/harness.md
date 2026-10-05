# Apple platform harness

The [Swift harness](../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessService.swift)
builds and exercises the app shells through Xcode and headless simulators.
Start with the [contributor setup](../CONTRIBUTING.md), then check the host:

```bash
mise run doctor -- --output json
mise run harness -- help
```

[Doctor](../Tools/PutioHarness/Sources/PutioHarnessKit/Doctor.swift) checks the
selected Xcode, pinned Tuist version, matching simulator runtimes and device types,
and the generated workspace. Its required failures exit nonzero; the optional live
putio CLI produces a warning. The [doctor wrapper](../scripts/doctor.sh) reports toolchain
failures even when Swift cannot compile the harness.

App builds use Debug and compile only the host's simulator architecture, locally
and on CI. Device builds are unchanged. `mise run build` also compiles every app
scheme in Release for the simulator, unoptimized and unsigned, so non-Debug
branches keep compiling; optimized builds come from the beta and release
archives. Release builds ignore harness launch arguments. `test` compiles its
suites before it creates a Simulator, because a freshly booted one keeps every
core busy. Right after an iOS Simulator boots, the harness unloads the system
jobs the apps never use, such as Siri, Health, and Mail sync, which roughly
halves that work. Commands that take 10 seconds or more print their duration.

## Choose the proof

Use a journey for an interactive flow:

```bash
mise run harness -- journey --platform ios --scenario files-browser
mise run harness -- journey --platform tvos --scenario device-sign-in
```

The iOS journey runs feature preflights and records the sign-in, browse, playback,
and sign-out loop. [BrowserJourneyContract](../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift)
owns the selected tests and required screenshots; the
[UI tests](../Tests/iOSUITests/Sources) contain their assertions. HTTP responses
and OAuth input come from [fixtures](../Apps/Shared/Sources/Harness/HarnessSeededAPI.swift).
Session transitions, navigation, and AVFoundation playback are real; media is
served by the harness's [loopback server](../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessMediaServer.swift).
Cast uses a [stub receiver](../Apps/iOS/Sources/Harness/ChromecastHarness.swift), so this
journey cannot establish compatibility with a physical Chromecast.

Accessibility preflights use the largest Dynamic Type size and enable Reduce
Motion in simulator Settings, restoring its prior value afterward. They exercise
long filenames, selection, downloads, and audio controls in portrait and landscape.
Slider dragging does not prove VoiceOver gestures, spoken output, or focus order.

The [tvOS journey](../Tests/tvOSUITests/Sources/DeviceSignInJourneyTests.swift)
drives code expiry, approval, restored sign-in, and sign-out using simulated
Siri Remote input. HTTP responses are fixtures; device-code polling, keychain,
and UI run in the app. Its [signed-in tests](../Tests/tvOSUITests/Sources/AccountHistoryTrashJourneyTests.swift)
record Home, History, Account, the proxy chooser, and Trash, with their
centered modals, empty states, and recovery from the fixtures' one-time
failures. Clearing History turns it off on the fixture account, so the Home
capture after it shows the gate following an account change. The
[browser tests](../Tests/tvOSUITests/Sources/FilesSearchJourneyTests.swift)
record Your Files with its sort and long-press menus, paging, empty, error, and
recovery states, the unsupported-type screen, and Search on the system keyboard.
`--putio-harness-tv-browse` adds the empty and failing folders, a second root
page that fails once and holds two files, and a root row that appears while
Harness Folder is open, for the refetch on return. The Search test runs with
`--putio-harness-trash-disabled`, so its menu offers a confirmed permanent delete.
The [playback tests](../Tests/tvOSUITests/Sources/PlaybackJourneyTests.swift)
stream the bundled HLS fixtures from the same loopback server: the resume
decision with both choices, the successor's Up Next and its start over, a
position report on the 15-second cadence, the system player's subtitle and
speed menus with the audio track kept, and the conversion gate with its
one-time failure. `--putio-harness-subtitled-stream` serves the multi-audio
fixture shaped by the account's subtitle settings, as on iOS.

For launch and rendering evidence, use:

```bash
mise run harness -- proof --platform ios
mise run harness -- screenshot --platform ios --scenario gallery
```

`proof` checks a rendered launch, an exercised state transition, the app's
semantic exercise signal, and process liveness, then records the transition and
captures the exercised screen. **The default tvOS launch reaches put.io to request
an activation code**, including through `proof --platform all`; use the tvOS
journey for deterministic, offline sign-in coverage.

The [argument parser](../Tools/PutioHarness/Sources/PutioHarnessKit/ArgumentParser.swift)
owns command options and supported platform/scenario combinations; `help` prints
its usage. Simulator evidence does not establish physical-device behavior,
production signing, background execution, or hardware remote/Watch behavior;
use a [physical Apple TV](#physical-apple-tv) for tvOS device evidence.

## Physical Apple TV

Device-only tvOS behavior, such as hardware decoding, watchdog terminations,
and Siri Remote input, needs a paired Apple TV. Pairing is manual and happens
once per Mac:

1. Put the Mac and the Apple TV on the same local network.
2. On the Apple TV, open Settings > Remotes and Devices > Remote App and Devices.
3. On the Mac, open Xcode's device window: Device Hub in Xcode 27 (Xcode > Open
   Developer Tool > Device Hub, or Manage Devices in the run destination menu),
   Window > Devices and Simulators in Xcode 26. Select the discovered Apple TV,
   choose Pair, and enter the code shown on the TV.
4. Confirm the pairing and note the Apple TV's UDID:

   ```bash
   xcrun devicectl list devices
   ```

   The Apple TV must appear with its `Identifier` and state `available (paired)`.

Debug device builds are signed with automatic provisioning. Export the Apple
development team that can sign `io.put.dev.tvos`, then build, launch, or
capture proof on the device:

```bash
export PUTIO_DEVELOPMENT_TEAM=<team-id>
mise run harness -- build --platform tvos --device <udid>
mise run harness -- launch --platform tvos --device <udid>
mise run harness -- proof --platform tvos --device <udid>
```

`--device` accepts the UDID, CoreDevice identifier, or device name from
`devicectl`; the [PhysicalDeviceHarness](../Tools/PutioHarness/Sources/PutioHarnessKit/PhysicalDeviceHarness.swift)
refuses devices that are not paired Apple TVs and lists the ones it can use.
The build passes `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`,
so the first run may register the Apple TV with the team.

On the device, `launch` and `proof` install the Debug app, terminate any running
instance, launch it with its console attached, wait up to 30 seconds for the
screen to change, and require it to stay running for `--record-seconds`. `proof`
follows the same clean-source rules as simulator proof and writes `launch.png`,
`app.console.log`, and a manifest under `build/proof/<run-id>/tvos/`; it fails
when `devicectl` does not report the Apple TV model and tvOS version.

Device proof is launch and rendering evidence only: it has no exercise step or
recording, and it drives no playback or remote input. Reinstalling keeps the
app's keychain, so the launch shows whatever session the Apple TV already has,
recorded as fixture set `device-installed-state-v1`; review `launch.png` for
the state it captured. The app stays installed afterward.

## Snapshot comparison

```bash
mise run harness -- test --platform ios
mise run harness -- test --platform tvos
```

These commands run the platform's `snapshotSuites` from
[HarnessPlatform.configuration](../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift)
and are part of [repository verification](../scripts/verify.sh).

[SnapshotRendering.swift](../Tests/Shared/SnapshotSupport/SnapshotRendering.swift)
owns baseline paths, comparison tolerance, and failure images. iOS rasterizes
the hosted view's layer off-screen. tvOS 27 draws bordered controls as Liquid
Glass, which off-screen layer rendering leaves as undefined solid fills, so both
tvOS suites are app-hosted and capture through the render server. Missing brand
fonts allow rendering with system fallbacks, then skip brand-baseline comparison;
with `PUTIO_REQUIRE_BRAND_FONTS=1`, which CI sets once it installs the fonts, they
fail instead. Each suite writes a result bundle under `build/DerivedData/Logs/Test`,
and `test` fails unless the suite ran at least one test with no failures, and with
no skips when fonts are required.
Gallery pages whose native layout changed in OS 27 keep a separate `-ios27` or
`-tvos27` baseline beside the shared one. Recording requires `mise run fonts-setup`
and is refused when `CI=true`. After an intentional visual change:

```bash
mise run harness -- test --platform ios --snapshots record
```

Recording also compares against the newly written images. Review and commit the
image diff. Off-screen snapshots use bordered/material fallbacks for Liquid
Glass; review glass itself with a gallery capture.

## Source and artifact ownership

`screenshot`, `record`, `proof`, and `journey` require a clean Git worktree,
including untracked files: they pin `HEAD`, regenerate the workspace, and check
the revision again before writing a success manifest. Commit the candidate
before capturing proof; `build` and `test` can run while editing.

Artifacts stay under ignored `build/proof/<run-id>/<platform>/`. The manifest
records source and simulator provenance plus artifact sizes and SHA-256 digests.
[SimulatorHarness](../Tools/PutioHarness/Sources/PutioHarnessKit/SimulatorHarness.swift)
owns capture validation and artifact emission. Journeys validate the selected
test results and required screenshots before emitting a success manifest. The
iOS walk is trimmed around screenshot-matched sign-in, playback, and sign-out
landmarks, excluding setup and teardown.

Failed journeys retain local diagnostics, including `.xcresult` bundles, and
remove the success manifest. Inspect that run directory and use a new `--run-id`
for a retry. Failed preflights also attempt to save audio error domains and codes
beside their result bundle before simulator cleanup; media URLs are excluded.
[harness-ci.sh](../scripts/harness-ci.sh) assigns a unique CI or local
run identity; set `PUTIO_HARNESS_RUN_ID` only when the caller needs to supply one.

## Simulator cleanup

The harness never opens Simulator.app. Each simulator command selects a device
from its runtime’s supported device types and creates uniquely named devices.
watchOS also gets an ephemeral paired iPhone. Devices are shut down, deleted,
and checked for absence when the command finishes or fails.
`build` creates no devices, and `boot` cleans up before returning.

Cleanup is registered before creation and uses the exact owned device ID. If
interrupted before `simctl create` returns, it retries lookup by the unique name
to catch a device whose creation finishes after the client exits. The
[interruption check](../scripts/test-harness-interruption.sh) covers this while
preserving preexisting devices. If cleanup fails, inspect the reported IDs and
remove only the run's devices with `xcrun simctl delete <udid>` before retrying.

## Live profile and publishing

Deterministic journeys need no account or secret. Live checks use the global
put.io CLI:

```bash
mise run harness -- auth-status --output json
mise run harness -- live-fixture --output json
```

[LiveAdapters](../Tools/PutioHarness/Sources/PutioHarnessKit/LiveAdapters.swift)
requires the `devs-auto` profile, removes ambient `PUTIO_CLI_TOKEN` from its
put.io child processes, and verifies profile authentication before writes.
`live-fixture` reuses the `putio-ios-harness` root folder and its `live-fixture.png`
image, uploaded from the [preview fixtures](../Tests/HarnessMedia/previews), and
validates each missing write with `--dry-run` first. Both stay in place for later
runs. Authenticate with `putio auth login --profile devs-auto` if the profile
check fails.

Live journeys sign the Debug app in to that account:

```bash
mise run harness -- journey --platform tvos --scenario live-device-sign-in
mise run harness -- journey --platform ios --scenario live-files-browser
```

The app launches with the `live` scenario against put.io, keeping its token under
the harness keychain item. On iOS, Sign in starts the device-code flow instead of
the web login; that path is compiled out of Release. The app writes the code it
displays to its data container, and the harness approves it with
`putio auth approve`, which links a new grant for the app to the account. The
token stays inside the app; the harness never sees it. The tvOS journey then
signs out through the account screen. The iOS journey first opens the fixture
folder and previews the image. Neither journey writes files.

Signing out revokes the run's grant. Sign-out removes the saved token before it
revokes it, so the live scenario's token store keeps a pending-revocation copy
until put.io revokes or rejects the token. Then the app records the revocation in
its data container. After any approval, even in a failed journey, the harness
relaunches the app with `--putio-harness-live-sign-out`. The app restores the
saved or pending token, signs it out, and reports the result. The harness makes
up to three attempts while a launch fails, times out, or cannot revoke the saved
token. A missing token is not proof: the
journey passes only when put.io revoked or rejected the token in this launch or
an earlier one. The journey and the interrupt handler share one guard for the
run's grant. The approval write runs inside it, so SIGINT or SIGTERM either
cancels an approval that has not started or revokes after it finishes. Revocation
runs once, before simulator deletion. Interrupt cleanup waits for a simulator
teardown the finished command has already started, and otherwise does the
teardown itself. If an approval is interrupted before the app saves its
token, nothing in the simulator can revoke the grant. The harness then reports
that the grant may still be live and names the manual revocation.

The CLI refuses to list authorized apps. The iOS journey captures Account >
Security > "Where you're signed in" while signed in, but put.io lists grants per
app, not per session, so that screen cannot show whether one run's token is gone.
The cleanup result is the per-run evidence. That capture shows every app on the
shared account, so review it before sharing.

Capture never uploads implicitly. Review the artifact, then upload it to the
pull request:

```bash
gh pr comment <number> --attach build/proof/<run-id>/ios/exercised.png
```

Structured failures pass through [HarnessOutput.redact](../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessService.swift).
Inspect retained diagnostics locally before sharing them.

## CI coverage

[Next CI](../.github/workflows/ci-next.yml) owns branch triggers, toolchain
selection, font provisioning, and checks. It runs each `mise run verify` lane and
the iOS launch-proof subset in `mise run harness-ci` on its own runner, five in
parallel; the proof reuses the build runner's compilation cache. Pull requests
skip the iOS lanes and proof when every change is tvOS-only or documentation, and
the tvOS suites when every change is iOS- or watchOS-only or documentation;
pushes to `next` and dispatches with `verify` run every lane. Each runner enables Xcode compilation caching
through `XCODE_XCCONFIG_FILE`; pushes to `next` build on that ISO week's cache
and save it, the first push of a week builds cold, and pull requests restore the
latest one. Runners also reuse a cached harness binary keyed on its sources, and
skip `tuist install` when its dependency cache matches exactly. A Simulator boot
that takes 3 minutes or more prints its `bootstatus` progress. The iOS tests and
proof jobs restore a cached `putio-template-*` device that has already booted
once and set `PUTIO_SIMULATOR_TEMPLATES=1`, so the harness clones it and skips
first-boot data migration. The template is keyed on the Xcode build, the iOS
runtime build, and the CoreSimulator version, so it survives runner image
updates. On a miss, a push to `next` has the harness create the template and
saves it after a green run; a pull request boots a fresh device. When a test fails,
its runner uploads the `.xcresult` bundles from `build/DerivedData/Logs/Test` as
a five-day artifact.
Feature journeys are separate; run the affected journey for local interactive
evidence.
