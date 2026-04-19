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

- Default shared item:
  - `frontend-ci/putio-ios`
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

- Required CI-only 1Password fields:
  - `APPSTORE_CONNECT_ISSUER_ID`
  - `APPSTORE_CONNECT_KEY_ID`
  - `PUTIO_APP_IDENTIFIER`
  - `PUTIO_APPLE_ID`
  - `PUTIO_ITC_TEAM_ID`
  - `PUTIO_DEVELOPMENT_TEAM`
  - `PUTIO_OAUTH_CLIENT_ID`
  - `PUTIO_CHROMECAST_RECEIVER_APP_ID`
  - `PUTIO_INTERCOM_API_KEY`
  - `PUTIO_INTERCOM_APP_ID`
  - `PUTIO_SENTRY_DSN`
  - `MATCH_GIT_URL`
  - `MATCH_TYPE`
  - `MATCH_PASSWORD`
  - `MATCH_GIT_PRIVATE_KEY`
    - store the SSH private key that matches the read-only deploy key on the certificates repo
- Match repo notes:
  - `putdotio/apple-certificates` is pinned to the `main` branch in `fastlane/Matchfile`
  - only the repo URL, password, and SSH key live in 1Password
- Required 1Password attachment:
  - `AuthKey.p8`
- Field-name contracts:
  - `Config/Local.1password.xcconfig.template`
  - `fastlane/.env.1password.template`

## Run Locally

- Open the workspace in Xcode:

```bash
open Putio.xcworkspace
```

- Quick local path:

```bash
make verify
make run-simulator
```

## Validation

- Repo verify:

```bash
make verify
```

- Useful helpers:

```bash
make print-simulator-destination
make print-simulator-device
make download-ios-platform
```

- Notes:
  - `make verify` uses an unsigned simulator build
  - `make run-simulator` uses a normal signed Simulator build so auth and keychain persistence behave like a real interactive run
  - any iPhone simulator on iOS `26.0+` is fine

## CI And Delivery

- See [docs/DISTRIBUTION.md](./docs/DISTRIBUTION.md) for:
  - workflow roles
  - CI bootstrap behavior
  - fastlane release contract
  - TestFlight distribution notes
  - signing and App Store Connect gotchas

## Development Notes

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- Fastlane passes the same `PUTIO_*` values through Xcode during beta archive builds
- Keep repo-stored configuration open-source-safe
  - do not commit tokens, signing keys, API key files, or private release metadata

## Known Debt

- The app is still a legacy UIKit and storyboard codebase
- Some large feature areas, especially Files and Settings, have been split into smaller units but still carry historical complexity
- Localization coverage is incomplete and should be treated as follow-up work, not a blocker for OSS
- Beta and release delivery are CI-only and intentionally documented in [docs/DISTRIBUTION.md](./docs/DISTRIBUTION.md)

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
