# Agent Guide

## Repo

- Native iOS app repository for put.io
- Current stack: UIKit app, CocoaPods dependencies, Bundler-managed Ruby tooling, optional fastlane release lane

## Start Here

- product overview and repo navigation: [README.md](./README.md)
- contributor workflow: [CONTRIBUTING.md](./CONTRIBUTING.md)
- security policy: [SECURITY.md](./SECURITY.md)

## Commands

- `make bootstrap`
- `make verify`
- `make print-simulator-destination`
- `make print-simulator-device`
- `make run-simulator`
- `make download-ios-platform`

## Repo-Specific Guidance

- Keep checked-in defaults open-source-safe. Private service keys stay out of git
- Build-time app settings flow through `Config/Shared.xcconfig`, optional `Config/Local.xcconfig`, and `Info.plist` placeholders
- Fastlane release lanes use the same `PUTIO_*` environment variables from `fastlane/.env` and pass them through to Xcode
- The repo also supports a 1Password-backed local flow via `scripts/op-local-config.sh` and `scripts/op-fastlane.sh`
- The `op` helpers default to the shared `frontend-ci/putio-ios` item and accept either an interactive signed-in `op` session or `OP_SERVICE_ACCOUNT_TOKEN`
- The checked-in app build should work without private release credentials
- Unsigned local verification should prefer the repo `make verify` entrypoint
- `make verify` prefers an Xcode-advertised iPhone simulator destination on iOS `26.0+` and falls back to the installed `iphonesimulator` SDK when Xcode is not exposing one yet
- `make print-simulator-destination` shows the concrete iPhone simulator destination the repo would use when Xcode can advertise one
- `make print-simulator-device` shows the fallback iPhone simulator device id the repo can use for manual install and launch flows
- `make run-simulator` builds for `iphonesimulator`, boots an available iPhone simulator on iOS `26.0+`, installs the app, and launches it with `simctl`
- Running the app in Simulator UI still depends on an installed iOS `26.x` platform and simulator runtime through Xcode Components
- Treat `fastlane/.env.example` as the contract for optional release-time configuration
- Prefer simulator-safe verification and unsigned builds in automation
- Update docs when setup, validation, or release expectations change
