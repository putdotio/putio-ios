# put.io Apple apps verification map

This map is the maintained source for verifying the apps' user-facing features.
Read this index, then use the matching feature file as the recipe.

## Baseline preconditions

- The candidate is committed and `mise run doctor` passes.
- iOS recipes run against the seeded `files-browser` fixtures. They need no
  account, token, or network.
- Every iOS recipe runs through
  `mise run harness -- journey --platform ios --scenario files-browser --only <preflight>`.
  The preflight names come from `BrowserJourneyContract.preflights` in
  [Models.swift](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift).
- tvOS recipes run the whole `device-sign-in` journey; it has no `--only`.
- No other journey runs on the host while you measure flakes.

## Driving conventions

- A recipe's preflight is an XCUITest under
  [Tests/iOSUITests](../../../../Tests/iOSUITests/Sources). Read its assertions
  for the exact handles; this map names the user path and the proof.
- Stable handles are accessibility identifiers such as `files.menu`,
  `files.item.<id>`, and `auth.sign-out`. Tab buttons use their visible names:
  Files, Downloads, History, Account, Search.
- To change a feature's behavior, change its preflight and this map together.

## Proof and skip reporting

- Proof is the passing preflight plus its named screenshots under
  `build/proof/<run-id>/ios/`. Open the screenshots.
- A feature with no preflight is unverified. Report it; a different feature's
  pass does not cover it.
- Report a failed preflight with its result bundle path and the failing step
  ([diagnosis](../references/journeys.md#diagnose-a-failed-preflight)).

## Feature entry contract

Each feature file starts with an H1 title and one paragraph on the user-visible
behavior, then four H2 sections in this order: `Sub-features`,
`How to get to it (user POV)`, `Driving it with the harness`, and `Gotchas`.

## Features

- [Files](./files.md): browse, sort, search, file actions, bulk selection,
  Trash, previews, and deep links.
- [Playback](./playback.md): video, resume, audio, subtitles, playback
  preferences, Cast, and downloads.
- [Account](./account.md): sign-out recovery, security, preferences, history,
  rating, and the analytics prompt.
- [tvOS](./tvos.md): device-code sign-in, browse, search, Trash, and playback.
