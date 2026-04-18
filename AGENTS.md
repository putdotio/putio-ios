# Agent Guide

## Repo

- Native iOS app repository for put.io
- Current stack: UIKit app, CocoaPods dependencies, Bundler-managed Ruby tooling, optional fastlane release lane

## Start Here

- product overview and repo navigation: [README.md](./README.md)
- contributor workflow: [CONTRIBUTING.md](./CONTRIBUTING.md)
- security policy: [SECURITY.md](./SECURITY.md)

## Commands

- `bundle install`
- `bundle exec pod install`
- `xcodebuild -list -workspace Putio.xcworkspace`
- `xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

## Repo-Specific Guidance

- Keep checked-in defaults open-source-safe. Private service keys stay out of git
- The checked-in app build should work without private release credentials
- Local verification currently expects the iOS `26.4` platform package to be installed through the Apple toolchain components
- Treat `fastlane/.env.example` as the contract for optional release-time configuration
- Prefer simulator-safe verification and unsigned builds in automation
- Update docs when setup, validation, or release expectations change
