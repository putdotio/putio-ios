# Contributing

Thanks for contributing to `putio-ios`.

## Setup

### OSS Contributors

- Prerequisites:
  - Xcode `26.x`
  - iOS `26.x` simulator runtime
  - Ruby from `.ruby-version`
- Install dependencies:

```bash
make bootstrap
```

- Optional private local overrides:
  - copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`
  - keep `Config/Local.xcconfig` out of git
  - checked-in defaults already use the dedicated local dev app identity `io.put.dev`
  - `Config/Local.xcconfig` is for secrets and team settings, not bundle-id overrides

### put.io Teammates

- Shared 1Password item: `frontend-ci/putio-ios`
- Local private config helper:

```bash
make op-local-config
```

- Local teammate builds default to:
  - bundle id `io.put.dev`
  - display name `put.io`
  - primary icon `AppIconDev`
- `make op-local-config` only materializes private local credentials and the development team
- CI beta builds still override app identity through secrets and fastlane
- Keep the shared item aligned with:
  - `Config/Local.1password.xcconfig.template`
  - `fastlane/.env.1password.template`
- Release automation also expects the `AuthKey.p8` attachment and the match repo SSH key material

## Run And Validate

- Open the workspace in Xcode:

```bash
open Putio.xcworkspace
```

- Quick local path:

```bash
make verify
make run-simulator
```

- Useful helpers:

```bash
make print-simulator-destination
make print-simulator-device
make download-ios-platform
plutil -lint Putio/en.lproj/*.strings
```

- Notes:
  - `make verify` uses an unsigned simulator build
  - `make run-simulator` uses a normal signed Simulator build so auth and keychain persistence behave like a real interactive run
  - any iPhone simulator on iOS `26.0+` is fine
  - when auth, keychain, or signed-in persistence changes, use both `make verify` and `make run-simulator`

## Targeted Regression Checks

- Focused xcodebuild runs are fine while iterating, but treat `make verify` as the repo gate before handoff
- Useful targeted suites after recent cleanup work:
  - `PutioTests/APIErrorLocalizerTests`
  - `PutioTests/ErrorPresentationTests`
  - `PutioTests/NavigationLocalizationTests`
  - `PutioTests/PutioRealmTests`

## Configuration Notes

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- Fastlane passes the same `PUTIO_*` values through Xcode during beta archive builds
- User-facing copy now has an English base under `Putio/en.lproj`
  - when changing copy in Swift, update `Putio/en.lproj/Localizable.strings`
  - when changing storyboard or xib copy, update the matching `Putio/en.lproj/*.strings` file
- Keep repo-stored configuration open-source-safe
  - do not commit tokens, signing keys, API key files, or private release metadata

## CI And Delivery

- See [docs/DISTRIBUTION.md](./docs/DISTRIBUTION.md) for:
  - workflow roles
  - CI bootstrap behavior
  - fastlane release contract
  - TestFlight distribution notes
  - signing and App Store Connect gotchas

## Known Debt

- The app is still a legacy UIKit and storyboard codebase
- Some large feature areas, especially Files and Settings, have been split into smaller units but still carry historical complexity
- English localization is extracted, but additional locale coverage is still follow-up work

## Good First Contributions

- Add focused unit coverage around pure logic and model parsing
- Continue shrinking legacy UIKit hotspots without changing behavior
- Improve light mode and visual polish without changing release infrastructure
- Tackle localization and copy consistency in isolated follow-up pull requests

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
