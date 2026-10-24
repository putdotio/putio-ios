# tvOS

A viewer signs in with a device code, browses Your Files, searches, manages
History and Trash, and plays video with the system player and Siri Remote.

## Sub-features

- `device-sign-in` lets a code expire, shows a new one, signs in on approval,
  restores the session on relaunch, and signs out.
- `history-trash` shows History and Trash modals with empty, error, and recovery
  states.
- `settings` cycles the proxy chooser and the Trash toggle.
- `browse` sorts from the menu and recovers a failed load.
- `search` shows empty, error, and result states from system search.
- `playback` offers resume choices, continues episodes, keeps the audio track
  while subtitles and speed change, and waits for conversion.

## How to get to it (user POV)

- Launch signed out: the activation code screen.
- Home sections: Your Files, Search, History (while it is on), and Account,
  which leads to the proxy chooser and Trash (while it is on).
- A video row opens the system player.

## Driving it with the harness

Preconditions:

- Seeded `device-sign-in` fixtures. The journey needs no account or network.

- **Whole journey.** Run
  `mise run harness -- journey --platform tvos --scenario device-sign-in`. It
  runs every tvOS test in
  [TVJourneyContract](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift)
  and keeps their screenshots under `build/proof/<run-id>/tvos/`.

## Gotchas

- `proof --platform tvos` and `proof --platform all` reach put.io for a real
  activation code. Use this journey for offline coverage.
- Remote input is simulated. Use a [paired Apple TV](../references/apple-tv-device.md)
  for hardware evidence.
