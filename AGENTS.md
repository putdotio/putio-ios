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
- `make download-ios-platform`

## Repo-Specific Guidance

- Keep checked-in defaults open-source-safe. Private service keys stay out of git
- The checked-in app build should work without private release credentials
- Unsigned local verification should prefer the repo `make verify` entrypoint
- `make verify` prefers an Xcode-advertised iPhone simulator destination on iOS `26.0+` and falls back to the installed `iphonesimulator` SDK when Xcode is not exposing one yet
- `make print-simulator-destination` shows the concrete iPhone simulator destination the repo would use when Xcode can advertise one
- Running the app in Simulator UI still depends on an installed iOS `26.x` platform and simulator runtime through Xcode Components
- Treat `fastlane/.env.example` as the contract for optional release-time configuration
- Prefer simulator-safe verification and unsigned builds in automation
- Update docs when setup, validation, or release expectations change
