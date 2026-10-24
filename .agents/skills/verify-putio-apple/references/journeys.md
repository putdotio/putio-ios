# Journeys

## iOS files-browser journey

```bash
mise run harness -- journey --platform ios --scenario files-browser
mise run harness -- journey --platform ios --scenario files-browser --only file-actions,history
```

[BrowserJourneyContract](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift)
owns the run: an ordered `preflights` table (name, XCUITest, required
screenshots, time allowance), then the recorded walk `testRunnableAlphaLoop`.
The [UI tests](../../../../Tests/iOSUITests/Sources) own the assertions.

- Each preflight is its own `xcodebuild test-without-building` call. All of
  them share one simulator.
- Every selected preflight runs, even after one fails. The journey then names
  every failed preflight and skips the walk.
- `--only` takes preflight names from the table. It skips the walk, and its
  manifest names the preflights it proved. Use it to iterate on one feature or
  to loop a flaky preflight.
- The walk records sign-in, playback, and sign-out. The recording is trimmed
  around screenshot-matched landmarks, without setup and teardown.

What is real and what is a fixture:

- HTTP responses and OAuth input come from
  [HarnessSeededAPI](../../../../Apps/Shared/Sources/Harness/HarnessSeededAPI.swift).
  Some responses are delayed on purpose; the delays sit beside their routes.
- Session transitions, navigation, and AVFoundation playback are real. The
  [loopback server](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/HarnessMediaServer.swift)
  serves the media.
- Cast uses a [stub receiver](../../../../Apps/iOS/Sources/Harness/ChromecastHarness.swift).
- Harness launches, live ones included, skip the product analytics prompt
  unless `--putio-harness-analytics-prompt` asks for it.
- Accessibility preflights run at the largest Dynamic Type size, which the app
  caps at XX Large. They turn on Reduce Motion in the simulator's Settings and
  restore it afterward.

### Waits

Wait with [`appears(within:)`, `disappears(within:)`, and `becomesHittable(within:)`](../../../../Tests/iOSUITests/Sources/XCUIElement+Wait.swift).
XCTest's existence waits sleep a full second before they first look.
`appears` also waits until the element stops moving, so a tap lands where the
element is. Wait on the state the user waits on, such as a toast going away or a
title changing, never on a fixed sleep.

### Diagnose a failed preflight

The failed preflight's bundle stays at
`build/proof/<run-id>/ios/.<preflight>.xcresult`.

1. Read the failure and the step log:
   `xcrun xcresulttool get test-results tests --path <bundle> --compact`, then
   `xcrun xcresulttool get test-results activities --path <bundle> --test-id '<Class>/<test>()' --compact`.
   Each activity has a start time; compare the failing step with the steps
   before it.
2. Export the screen recording, UI snapshots, and element debug descriptions:
   `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`.
   `manifest.json` maps each file to its name and timestamp.
3. Extract frames around the failure with `ffmpeg -ss <seconds> -i <recording> -frames:v 1 <png>`.
   The recording starts at the "Start Test" activity. A failed preflight also
   tries to save audio error domains and codes in `.<preflight>.audio.log`.
4. Before you call a failure a flake, look for something in the app that changed
   at that moment, such as a toast hiding, a refresh landing, or a sheet
   animating. Write a repro test that sweeps the tap time across that moment,
   and fix the cause in the app or the test.
5. Loop the preflight with `--only <name>` and a new `--run-id` until it passes
   every run, one run at a time.

## tvOS

```bash
mise run harness -- journey --platform tvos --scenario device-sign-in
```

[TVJourneyContract](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift)
owns the tests and screenshots. Siri Remote input is simulated. HTTP responses
are fixtures; device-code polling, the keychain, and the UI run in the app.

- [DeviceSignInJourneyTests](../../../../Tests/tvOSUITests/Sources/DeviceSignInJourneyTests.swift):
  code expiry, approval, restored sign-in, and sign-out.
- [AccountHistoryTrashJourneyTests](../../../../Tests/tvOSUITests/Sources/AccountHistoryTrashJourneyTests.swift):
  Home, History, Account, and Trash, with empty, error, and recovery states.
- [FilesSearchJourneyTests](../../../../Tests/tvOSUITests/Sources/FilesSearchJourneyTests.swift):
  Your Files, sort, and Search.
- [PlaybackJourneyTests](../../../../Tests/tvOSUITests/Sources/PlaybackJourneyTests.swift):
  the system player, resume, episodes, subtitles, speed, and conversion, with
  media from the loopback server.
