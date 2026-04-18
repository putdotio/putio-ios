# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Install the Apple development toolchain with simulator support, the iOS `26.4` platform package in Components, Ruby `3.2.4`, and Bundler, then install the repo dependencies:

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
xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Development Notes

- The checked-in repo disables private support integrations by default. `PUTIO_INTERCOM_API_KEY`, `PUTIO_INTERCOM_APP_ID`, and `PUTIO_SENTRY_DSN` are blank in `Putio/Info.plist`
- The OAuth client id is still configured by default so the existing browser-based login flow keeps working in local builds
- The current project settings expect the iOS `26.4` platform package to be installed locally. Missing that package blocks storyboard compilation before Swift compilation finishes
- Release automation is optional and env-driven. Populate `fastlane/.env` from `fastlane/.env.example` only when you need the internal release lane
- Keep repo-stored configuration open-source-safe. Do not commit tokens, signing keys, API key files, or private release metadata

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
