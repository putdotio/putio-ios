# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Install Xcode `26.x` and the Ruby version from `.ruby-version`, then install the repo dependencies:

```bash
make bootstrap
```

That bootstrap step installs Bundler gems, CocoaPods dependencies, and the current `PutioSDK` app dependency graph

For private app configuration and signing overrides, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill in the values your team needs. Keep that local file out of git.

If your team keeps iOS release secrets in 1Password, you can skip hand-editing local files and use the built-in 1Password flow instead:

```bash
./scripts/sync-local-config-from-1password.sh --vault "<vault>" --item "putio-ios"
./scripts/fastlane-with-1password.sh --vault "<vault>" --item "putio-ios" beta
```

That flow expects a single 1Password item with these text fields:

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

Add the App Store Connect `.p8` key to that same item as a file attachment named `AuthKey.p8`.

The committed templates at `Config/Local.1password.xcconfig.template` and `fastlane/.env.1password.template` are the source of truth for the expected field names.

## Run Locally

Open the workspace and run the `Putio` scheme on any available iPhone simulator running iOS `26.0` or newer:

```bash
open Putio.xcworkspace
```

## Validation

Run the same local bootstrap CI depends on:

```bash
make verify
```

To see the concrete iPhone simulator destination Xcode is advertising to the repo on your machine, run:

```bash
make print-simulator-destination
```

To boot an available iPhone simulator, install the unsigned app bundle, and launch it with `simctl`, run:

```bash
make run-simulator
```

To see the fallback simulator device id that run path will use, run:

```bash
make print-simulator-device
```

## Development Notes

- The checked-in repo disables private support integrations by default. `PUTIO_INTERCOM_API_KEY`, `PUTIO_INTERCOM_APP_ID`, and `PUTIO_SENTRY_DSN` are blank in `Putio/Info.plist`
- The OAuth client id is still configured by default so the existing browser-based login flow keeps working in local builds
- The app depends on the `PutioSDK` pod for put.io API integration
- Native app runtime settings come from build settings through `Config/Shared.xcconfig`, optional `Config/Local.xcconfig`, and `Info.plist` placeholders
- Fastlane uses the same `PUTIO_*` environment variables from `fastlane/.env` and passes them through to Xcode during release builds
- The 1Password helper scripts load those same values through `op inject` and `op run` from one shared item and materialize the App Store Connect key as a temporary local file only for the duration of the fastlane run
- `make verify` prefers any Xcode-advertised iPhone simulator destination on iOS `26.0+` and falls back to the installed `iphonesimulator` SDK when Xcode is not exposing one yet
- `make run-simulator` uses `simctl` to boot an available iPhone simulator on iOS `26.0+`, install the unsigned app bundle, and launch it when Xcode destination discovery is not enough for an interactive run
- The exact simulator version does not need to be `26.4`; any iPhone simulator on iOS `26.0` or newer is fine for interactive local runs
- If you see `iOS 26.4 Platform Not Installed`, that is an Xcode platform-component issue rather than a repo destination issue. Run `make download-ios-platform` or install the matching iOS `26.x` platform and simulator components through Xcode Settings first
- Release automation is optional and env-driven. Populate `fastlane/.env` from `fastlane/.env.example` only when you need the internal release lane
- Keep repo-stored configuration open-source-safe. Do not commit tokens, signing keys, API key files, or private release metadata

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
