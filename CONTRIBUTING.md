# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Install Xcode `26.x`, Ruby `3.2.4`, and Bundler, then install the repo dependencies:

```bash
make bootstrap
```

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

## Development Notes

- The checked-in repo disables private support integrations by default. `PUTIO_INTERCOM_API_KEY`, `PUTIO_INTERCOM_APP_ID`, and `PUTIO_SENTRY_DSN` are blank in `Putio/Info.plist`
- The OAuth client id is still configured by default so the existing browser-based login flow keeps working in local builds
- `make verify` prefers any Xcode-advertised iPhone simulator destination on iOS `26.0+` and falls back to the installed `iphonesimulator` SDK when Xcode is not exposing one yet
- The exact simulator version does not need to be `26.4`; any iPhone simulator on iOS `26.0` or newer is fine for interactive local runs
- If you see `iOS 26.4 Platform Not Installed`, that is an Xcode platform-component issue rather than a repo destination issue. Run `make download-ios-platform` or install the matching iOS `26.x` platform and simulator components through Xcode Settings first
- Release automation is optional and env-driven. Populate `fastlane/.env` from `fastlane/.env.example` only when you need the internal release lane
- Keep repo-stored configuration open-source-safe. Do not commit tokens, signing keys, API key files, or private release metadata

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
