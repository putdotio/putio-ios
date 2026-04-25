# Agent Guide

## Repo

- Native iOS app repository for put.io
- Stack: UIKit, CocoaPods, Bundler-managed Ruby

## Start Here

- [Overview](./README.md)
- [Contributing](./CONTRIBUTING.md)
- [Distribution](./docs/DISTRIBUTION.md)
- [Security](./SECURITY.md)

## Commands

- `make bootstrap`
- `make verify`
- `make e2e-simulator`
- `make run-simulator`

## Rules

- Keep checked-in defaults open-source-safe
- Private service keys stay out of git
- Update docs when setup, validation, or release expectations change

## Agent Checks

- Use [Contributing](./CONTRIBUTING.md) for setup, local validation, teammate-only 1Password flow, and localization workflow
- Use [Distribution](./docs/DISTRIBUTION.md) for CI, TestFlight, and release-promotion rules
- When auth, keychain, or signed-in persistence changes, run both `make verify` and `make run-simulator`
- When SDK-backed app flows change, prefer `make e2e-simulator` for fast mocked simulator coverage before live-account checks
- When async UI loading code changes, keep expensive parsing or decoding off the main thread and make sure cancellation, back navigation, and failure paths do not leave stale spinners or disabled controls behind
- When user-facing copy changes, update the matching files under `Putio/en.lproj` and lint them with `plutil -lint Putio/en.lproj/*.strings`
- When preparing a PR or handoff, include the most helpful evidence for review: visual aids for UI changes, sanity checks for risky flows, and before or after benchmarks for performance-sensitive work

## Regression Hotspots

- Auth callback handling, post-login persistence, and user-facing recovery copy are covered by `PutioTests/ErrorPresentationTests.swift` and `PutioTests/PutioRealmTests.swift`
- Files action labels and related localization expectations are covered by `PutioTests/NavigationLocalizationTests.swift`
- File preview changes should be smoke-tested in Simulator with real image and PDF files when possible
