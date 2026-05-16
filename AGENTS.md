# Agent Guide

- Native Apple repository for put.io
- iOS app: UIKit, CocoaPods, Bundler-managed Ruby; sources under `Putio/`
- tvOS app: SwiftUI, depends on `PutioSDK`; sources under `PutioTV/`
- Shared rules in `.patterns/` apply to both targets; the UIKit iOS app keeps
  its prior conventions (UIKit, Realm, Storyboards) and the SwiftUI tvOS
  target adopts the `.patterns/` defaults from day one
- Tests live under `PutioTests`

## Start Here

- [Overview](./README.md)
- [Contributing](./CONTRIBUTING.md)
- [Distribution](./docs/DISTRIBUTION.md)
- [Security](./SECURITY.md)
- [PutioTV target setup](./docs/tvOS-native-target.md)
- [tvOS parity checklist](./docs/tvOS-parity-checklist.md)
- [Repo patterns](./.patterns/README.md)

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
- Use [Contributing](./CONTRIBUTING.md) for setup, local validation, teammate-only private config, and localization workflow
- Use [Distribution](./docs/DISTRIBUTION.md) for CI, TestFlight, and release-promotion rules

## Local Environment

Xcode + Fastlane carry their own config and signing flow; this repo does not use a `.envrc` / `secrets` task-runner pattern.

- A fresh worktree only needs `make bootstrap`; `make verify` and `make e2e-simulator` run without local secrets
- Use `make secrets-setup` only for signed local builds or private support integrations; it writes ignored `Config/Local.xcconfig` from maintainer-supplied `PUTIO_IOS_INFISICAL_*` values

Full human-facing setup lives in [Contributing](./CONTRIBUTING.md#local-private-config).

## Coding Patterns

### iOS target (`Putio/`)

- Prefer existing UIKit, storyboard, presenter, and view-model patterns before introducing new abstractions
- Keep feature behavior in the matching `Putio/Features/<Area>` folder and move only genuinely shared code into `Putio/Common`
- Route put.io API behavior through the local SDK wrapper in `Putio/Common/API` unless a focused system API is the smaller choice
- Use `PutioRealm` helpers for Realm open/write paths and include useful context strings for diagnostics
- Surface unexpected internal failures with `InternalFailurePresenter` instead of silent returns
- Update UI on the main thread, but keep expensive network response parsing, image decoding, and PDF parsing off the main thread
- Make every async loading path finish cleanly on success, failure, cancellation, and back navigation
- Put user-facing copy in localized strings; when Swift copy changes, update `Putio/en.lproj/Localizable.strings`
- Add dependencies only when the repo has no good platform or SDK option

### tvOS target (`PutioTV/`)

- SwiftUI primitives + the design tokens in `PutioTV/Design`. Liquid Glass material on toolbars and transient panels only — never as a content background
- One repository per SDK domain (`PutioTV/Core/Repositories/*`); view-models depend on the protocol, not the SDK directly
- Bug-sensitive flows (auth linking, playback, conversion) are modelled as explicit Swift enums; see `.patterns/state-machines.md`
- AVPlayer chrome is platform-owned — no custom video controls in phase one
- Lucide icons via `PutioTV/Design/Components/LucideIcon.swift`. Add new icon names there with an SF Symbol fallback rather than ad-hoc symbols at call sites
- Keep `PutioSDK` as the only network boundary; don't open `URLSession` directly

## Verification Matrix

- Any iOS behavior change: run `make verify`
- SDK-backed iOS flow: run `make e2e-simulator` before live-account checks
- When auth, keychain, or signed-in persistence changes on iOS, run both `make verify` and `make run-simulator`
- When user-facing copy changes, update the matching files under `Putio/en.lproj` and lint them with `plutil -lint Putio/en.lproj/*.strings`
- tvOS behavior change: build the `PutioTV` scheme against a tvOS 26 simulator destination (see [docs/tvOS-native-target.md](./docs/tvOS-native-target.md)) and capture a comparable screenshot for each affected row in [docs/tvOS-parity-checklist.md](./docs/tvOS-parity-checklist.md)
- When preparing a PR or handoff, include the most helpful evidence for review: visual aids for UI changes, sanity checks for risky flows, and before or after benchmarks for performance-sensitive work

## Regression Hotspots

- Auth callback handling, post-login persistence, and user-facing recovery copy are covered by `PutioTests/ErrorPresentationTests.swift` and `PutioTests/PutioRealmTests.swift`
- Files action labels and related localization expectations are covered by `PutioTests/NavigationLocalizationTests.swift`
- File preview changes should be smoke-tested in Simulator with real image and PDF files when possible
