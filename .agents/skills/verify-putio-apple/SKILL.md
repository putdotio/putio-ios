---
name: verify-putio-apple
description: Drives the put.io iOS, tvOS, and watchOS apps through the headless harness to prove behavior. Use to prove a runtime change, run or debug a journey or a flaky preflight, record snapshot baselines, capture Apple TV device proof, or sign in to the shared live account.
---

# Verify the put.io Apple apps

`mise run harness -- <command>` runs the [typed harness](../../../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessService.swift).
It builds the apps, owns its simulators, drives XCUITests, and writes evidence.
`mise run harness -- help` lists commands and options. The
[proof table](../../../AGENTS.md#verification-and-completion) picks the command for a change;
this skill explains how each one behaves.

## Launch

1. In a fresh checkout or worktree, run `mise run bootstrap`.
2. Commit the candidate first. `screenshot`, `record`, `proof`, and `journey`
   require a clean worktree, untracked files included. They pin `HEAD`,
   regenerate the workspace, and check the revision again before they write a
   success manifest. `build` and `test` run on a dirty tree.
3. Run one harness command per worktree: runs share `build/DerivedData`.
4. Run one journey per host when you measure flakes. Concurrent simulators
   change UI timing, so failures from overlapping runs do not count.

Harness builds are Debug for the host's simulator architecture, locally and on
CI. `mise run build` also compiles every app scheme in Release for the simulator,
unoptimized and unsigned. Release builds ignore harness launch arguments.

## Doctor

Run `mise run doctor -- --output json` first, and again when anything looks off.
It checks the selected Xcode, the pinned Tuist, the iOS, tvOS, and watchOS
runtimes and device types, and the generated workspace. Required failures exit
nonzero; a missing `putio` CLI only warns. The
[doctor wrapper](../../../scripts/doctor.sh) reports toolchain failures even when
Swift cannot compile the harness.

## Drive

| Proof                                   | Command                                                                           | Details                                    |
| --------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------ |
| iOS feature flows and the recorded walk | `journey --platform ios --scenario files-browser [--only <preflights>]`           | [journeys](references/journeys.md)         |
| tvOS sign-in, browse, and playback      | `journey --platform tvos --scenario device-sign-in`                               | [journeys](references/journeys.md#tvos)    |
| Launch and rendering                    | `proof --platform <ios\|watchos\|tvos\|all>`                                      | below                                      |
| One screen                              | `screenshot` or `record --platform <p> --scenario signed-out\|gallery\|signed-in` | below                                      |
| Components and theming                  | `test --platform <ios\|tvos> [--snapshots record]`                                | [snapshots](references/snapshots.md)       |
| tvOS on hardware                        | `build`, `launch`, or `proof --platform tvos --device <udid>`                     | [Apple TV](references/apple-tv-device.md)  |
| Real put.io account                     | `journey --scenario live-files-browser\|live-device-sign-in`                      | [live account](references/live-account.md) |

The [feature map](features/README.md) names the preflight that proves each
user-facing feature. `journey --only` runs just those preflights in a few minutes;
the full iOS journey takes about 30.

`proof` checks a rendered launch, an exercised state transition, the app's
semantic exercise signal, and process liveness. It then records the transition
and captures the exercised screen. `gallery` is for iOS and tvOS, and
`signed-in` is for iOS only.

**The default tvOS launch reaches put.io for an activation code**, including in
`proof --platform all`. Use the tvOS journey for offline sign-in coverage.

## Evidence

- Artifacts go to ignored `build/proof/<run-id>/<platform>/`. The manifest
  records source and simulator provenance, artifact sizes, and SHA-256 digests.
- A failed run keeps its diagnostics, `.xcresult` bundles included, and removes
  the success manifest. Use a new `--run-id` to retry.
  [harness-ci.sh](../../../scripts/harness-ci.sh) assigns a unique run ID; set
  `PUTIO_HARNESS_RUN_ID` only when the caller must supply one.
- Open the screenshots and recording yourself. A passing run is not proof that
  the screen looks right.
- Upload reviewed media with `gh pr comment <n> --attach <file>`. Media never
  goes in the branch. Structured failures pass through `HarnessOutput.redact`;
  read local diagnostics before you share them.
- Simulator evidence does not prove physical-device behavior, production
  signing, background execution, a physical Chromecast, VoiceOver, or hardware
  remote and Watch input.

## Cleanup

The harness never opens Simulator.app. It creates uniquely named devices from
the runtime's supported device types, plus a paired iPhone for watchOS. It
registers cleanup before creation and shuts down, deletes, and checks the
absence of each device it owns, on success, failure, SIGINT, or SIGTERM. If
interrupted before `simctl create` returns, it looks the device up by its unique
name. `build` creates no devices, and `boot` cleans up before it returns.

If cleanup fails, delete only the UDIDs the run reported:
`xcrun simctl delete <udid>`. Leave other simulators alone.

## CI

[Next CI](../../../.github/workflows/ci-next.yml) runs each `mise run verify` lane
and the iOS launch-proof subset (`mise run harness-ci`) on separate runners, and
uploads `.xcresult` bundles when a test fails. `PUTIO_SIMULATOR_TEMPLATES=1`,
set by the [setup action](../../../.github/actions/setup-apple/action.yml), clones a
cached, booted `putio-template-*` device. Feature journeys do not run in CI, so
run the affected journey or preflights locally.
