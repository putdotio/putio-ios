# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Install Xcode `26.4`, Ruby `3.2.4`, and Bundler, then install the repo dependencies:

```bash
bundle install
bundle exec pod install
```

## Run Locally

Open the workspace and run the `Putio` scheme in the simulator of your choice:

```bash
open Putio.xcworkspace
```

## Validation

Run the same local bootstrap CI depends on:

```bash
bundle exec pod install
xcodebuild -list -workspace Putio.xcworkspace
xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
```

## Development Notes

- The checked-in repo disables private support integrations by default. `PUTIO_INTERCOM_API_KEY`, `PUTIO_INTERCOM_APP_ID`, and `PUTIO_SENTRY_DSN` are blank in `Putio/Info.plist`
- The OAuth client id is still configured by default so the existing browser-based login flow keeps working in local builds
- The checked-in CI build compiles against `iphonesimulator` without code signing, which is more reliable than generic simulator destination resolution on this machine
- If you want to launch the app in Simulator UI, install a matching iOS `26.x` simulator runtime through Xcode Components first
- Release automation is optional and env-driven. Populate `fastlane/.env` from `fastlane/.env.example` only when you need the internal release lane
- Keep repo-stored configuration open-source-safe. Do not commit tokens, signing keys, API key files, or private release metadata

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
