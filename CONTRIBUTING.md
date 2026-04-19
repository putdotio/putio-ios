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

### put.io Teammates

- Default shared item:
  - `frontend-ci/putio-ios`
- Local private config helper:

```bash
make op-local-config
```

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

- `.github/workflows/ci.yml`
  - verify only
  - runs `make bootstrap-ci` and `make verify`
- `make bootstrap-ci`
  - reuses `Pods` when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale
- `.github/workflows/beta.yml`
  - manual TestFlight path
  - verifies first
  - loads secrets through `OP_SERVICE_ACCOUNT_PUTIO_FRONTEND_CI`
  - owns the `fastlane beta` invocation
  - always distributes to the external TestFlight groups configured for the run
  - splits the delivery flow into archive, upload, and distribute steps
  - uses a bounded App Store Connect processing timeout instead of waiting forever
- `.github/workflows/release.yml`
  - runs on published GitHub releases
  - builds from the release tag
  - owns the `fastlane release` invocation
- Build numbering:
  - uploaded beta and release builds use UTC timestamp build numbers in `YYMMDDHHMM` format
  - checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
  - fastlane temporarily updates tracked version metadata during archive time and restores the files afterward
- Fastlane contract:
  - release lanes are CI-only
  - `make beta` and `make release` intentionally fail locally
  - shared 1Password loading and secret materialization live in `.github/actions/load-ios-release-secrets/action.yml`

## Development Notes

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- Fastlane passes the same `PUTIO_*` values through Xcode during release builds
- Keep repo-stored configuration open-source-safe
  - do not commit tokens, signing keys, API key files, or private release metadata

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
