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
- `make download-ios-platform`

## Repo-Specific Guidance

- Keep checked-in defaults open-source-safe. Private service keys stay out of git
- The checked-in app build should work without private release credentials
- Unsigned local verification should prefer the repo `make verify` entrypoint and `-sdk iphonesimulator` over generic simulator destinations
- Running the app in Simulator UI still depends on a matching iOS `26.x` simulator runtime being installed through Xcode Components
- Treat `fastlane/.env.example` as the contract for optional release-time configuration
- Prefer simulator-safe verification and unsigned builds in automation
- Update docs when setup, validation, or release expectations change
