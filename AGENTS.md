# Agent Guide

- Native iOS app repository for put.io
- Stack: UIKit, CocoaPods, Bundler-managed Ruby
- App code lives under `Putio/Features` and shared helpers live under `Putio/Common`
- Tests live under `PutioTests`

## Start Here

- [Overview](./README.md)
- [Contributing](./CONTRIBUTING.md)
- [Distribution](./docs/DISTRIBUTION.md)
- [Security](./SECURITY.md)

## Core Commands

- `make bootstrap`
- `make verify`
- `make e2e-simulator`
- `make run-simulator`

## Workflow

- Keep checked-in defaults open-source-safe
- Private service keys stay out of git
- Update docs when setup, validation, or release expectations change
- Keep branches focused; prefer follow-up PRs over unrelated cleanup
- Use [Contributing](./CONTRIBUTING.md) for setup, local validation, teammate-only 1Password flow, and localization workflow
- Use [Distribution](./docs/DISTRIBUTION.md) for CI, TestFlight, and release-promotion rules

## Coding Patterns

- Prefer existing UIKit, storyboard, presenter, and view-model patterns before introducing new abstractions
- Keep feature behavior in the matching `Putio/Features/<Area>` folder and move only genuinely shared code into `Putio/Common`
- Route put.io API behavior through the local SDK wrapper in `Putio/Common/API` unless a focused system API is the smaller choice
- Use `PutioRealm` helpers for Realm open/write paths and include useful context strings for diagnostics
- Surface unexpected internal failures with `InternalFailurePresenter` instead of silent returns
- Update UI on the main thread, but keep expensive network response parsing, image decoding, and PDF parsing off the main thread
- Make every async loading path finish cleanly on success, failure, cancellation, and back navigation
- Put user-facing copy in localized strings; when Swift copy changes, update `Putio/en.lproj/Localizable.strings`
- Avoid adding dependencies unless the repo already has no good platform or SDK option

## Verification Matrix

- Any behavior change: run `make verify`
- SDK-backed app flow: run `make e2e-simulator` before live-account checks
- When auth, keychain, or signed-in persistence changes, run both `make verify` and `make run-simulator`
- When user-facing copy changes, update the matching files under `Putio/en.lproj` and lint them with `plutil -lint Putio/en.lproj/*.strings`
- When preparing a PR or handoff, include the most helpful evidence for review: visual aids for UI changes, sanity checks for risky flows, and before or after benchmarks for performance-sensitive work

## Regression Hotspots

- Auth callback handling, post-login persistence, and user-facing recovery copy are covered by `PutioTests/ErrorPresentationTests.swift` and `PutioTests/PutioRealmTests.swift`
- Files action labels and related localization expectations are covered by `PutioTests/NavigationLocalizationTests.swift`
- File preview changes should be smoke-tested in Simulator with real image and PDF files when possible
