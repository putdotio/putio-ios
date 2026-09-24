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

Local app builds use Debug and compile only the host's simulator architecture.
When `CI` or `GITHUB_ACTIONS` is present, builds retain the project's architecture
defaults. Run `CI=1 mise run build` locally to build both simulator architectures;
switching modes can trigger recompilation. Device and Release builds are unchanged.

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
and OAuth input come from [fixtures](../Apps/Shared/Sources/HarnessSeededAPI.swift).
Session transitions, navigation, and AVFoundation playback are real; media is
served by the harness's [loopback server](../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessMediaServer.swift).
Cast uses a [stub receiver](../Apps/iOS/Sources/ChromecastHarness.swift), so this
journey cannot establish compatibility with a physical Chromecast.

Accessibility preflights use the largest Dynamic Type size and enable Reduce
Motion in simulator Settings, restoring its prior value afterward. They exercise
long filenames, selection, downloads, and audio controls in portrait and landscape.
Slider dragging does not prove VoiceOver gestures, spoken output, or focus order.

The [tvOS journey](../Tests/tvOSUITests/Sources/DeviceSignInJourneyTests.swift)
drives code expiry, approval, restored sign-in, and sign-out using simulated
Siri Remote input. HTTP responses are fixtures; device-code polling, keychain,
and UI run in the app.

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
3. On the Mac, open Xcode > Window > Devices and Simulators, select the Apple TV
   under Discovered, choose Pair, and enter the code shown on the TV.
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

On the device, `launch` and `proof` install the Debug app, relaunch it with its
console attached, wait up to 30 seconds for the screen to change, and require it
to stay running for `--record-seconds`. `proof` follows the same clean-source
rules as simulator proof and writes `launch.png`, `app.console.log`, and a
manifest under `build/proof/<run-id>/tvos/`. The manifest's `deviceType` is the
Apple TV model identifier and `runtime` is its tvOS version and build; it omits
`simulatorName`. Device proof has no exercise step or recording, and the app
stays installed afterward. The launch reaches put.io to request an activation
code, as it does in the simulator.

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
fonts allow rendering with system fallbacks, then skip brand-baseline comparison.
The states gallery has a separate iOS 27 baseline for the native
`ContentUnavailableView` layout, and every tvOS gallery page but Transfers has
a tvOS 27 baseline for its native control metrics; other pages share their
existing baselines.
Recording requires `mise run fonts-setup`. After an intentional visual change:

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
`live-fixture` reuses the `putio-ios-harness` root folder or validates the create
request with `--dry-run` before writing. Authenticate with
`putio auth login --profile devs-auto` if the profile check fails.

Capture never uploads implicitly. Review the artifact and obtain publishing
authorization, then upload it to the pull request:

```bash
gh pr comment <number> --attach build/proof/<run-id>/ios/exercised.png
```

Structured failures pass through [HarnessOutput.redact](../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessService.swift).
Inspect retained diagnostics locally before sharing them.

## CI coverage

[Next CI](../.github/workflows/ci-next.yml) owns branch triggers, toolchain
selection, font provisioning, and checks. It runs `mise run verify` and the iOS
launch-proof subset in `mise run harness-ci`. Feature journeys are separate;
run the affected journey for local interactive evidence.
