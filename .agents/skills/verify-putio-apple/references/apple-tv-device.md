# Physical Apple TV

Hardware decoding, watchdog terminations, and Siri Remote input need a paired
Apple TV.

## Pair once per Mac

1. Put the Mac and the Apple TV on the same local network.
2. On the Apple TV, open Settings > Remotes and Devices > Remote App and Devices.
3. On the Mac, open Xcode's device window: Device Hub in Xcode 27 (Xcode > Open
   Developer Tool > Device Hub, or Manage Devices in the run destination menu),
   Window > Devices and Simulators in Xcode 26. Select the Apple TV, choose
   Pair, and enter the code the TV shows.
4. Run `xcrun devicectl list devices`. The Apple TV must show its `Identifier`
   and the state `available (paired)`.

## Build, launch, and capture

```bash
export PUTIO_DEVELOPMENT_TEAM=<team-id>
mise run harness -- build --platform tvos --device <udid>
mise run harness -- launch --platform tvos --device <udid>
mise run harness -- proof --platform tvos --device <udid>
```

`PUTIO_DEVELOPMENT_TEAM` is the Apple development team that can sign
`io.put.dev.tvos`. Debug device builds use automatic provisioning with
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, so the first
run may register the Apple TV with that team.

`--device` takes the UDID, CoreDevice identifier, or device name from
`devicectl`. [PhysicalDeviceHarness](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/PhysicalDeviceHarness.swift)
refuses devices that are not paired Apple TVs and lists the ones it can use.

`launch` and `proof` install the Debug app, stop any running instance, launch it
with its console attached, wait up to 30 seconds for the screen to change, and
require it to keep running for `--record-seconds`. `proof` follows the same
clean-source rules as simulator proof. It writes `launch.png`,
`app.console.log`, and a manifest under `build/proof/<run-id>/tvos/`. It fails
when `devicectl` does not report the Apple TV model and tvOS version.

## Limits

- Device proof is launch and rendering evidence only. It has no exercise step,
  no recording, no playback, and no remote input.
- Reinstalling keeps the app's keychain, so the launch shows the session the
  Apple TV already has. The manifest records fixture set
  `device-installed-state-v1`; check `launch.png` for the state it captured.
- The app stays installed afterward.
