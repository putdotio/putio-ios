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

- `make doctor`
- `make bootstrap`
- `make verify-fast`
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
- `make doctor` (also a `bootstrap` preflight) checks the active Ruby against `.ruby-version` and the Xcode developer directory, and prints copy-pasteable fixes when either is wrong
- `make bootstrap` installs the repo pre-push hook (`.githooks/pre-push`), which runs `make verify-fast` — icon sync check, localized strings lint, and workspace sanity — in under a second
- `make verify` and `make e2e-simulator` write test result bundles to `build/verify.xcresult` and `build/e2e-simulator.xcresult`; CI uploads them as artifacts on failure
- `make verify` and `make e2e-simulator` each create an ephemeral simulator (booted with a pinned status bar for deterministic screenshots) and delete it on exit, so parallel worktrees never collide; set `PUTIO_SIMULATOR_ID=<udid>` to target a specific device instead (`make run-simulator` keeps using the shared visible simulator)
- Visual baselines live in two tiers, both asserted with SnapshotTesting (perceptual tolerance): component-level snapshots in `PutioTests/__Snapshots__/` (buttons, cells, state views, both modes) and full-screen walk captures in `PutioUITests/__Snapshots__/` (13 screens × 2 modes); after an intentional visual change run `make screenshots-record` (re-records both tiers, fails on partial runs), review the image diff, and commit the new baselines
- E2e also runs weekly in CI (Mondays 06:00 UTC) via `.github/workflows/e2e-simulator.yml`
- Use `make secrets-setup` only for signed local builds or private support integrations; it writes ignored `Config/Local.xcconfig` from maintainer-supplied `PUTIO_IOS_INFISICAL_*` values
- `make fonts-setup` (optional, maintainers) syncs the licensed brand fonts from the private putio-static repository into gitignored `Putio/Fonts/` via `gh` auth, pinned by commit and checksum; local builds fall back to system fonts when absent, CI beta/release archives sync them via the `PUTIO_STATIC_READ_TOKEN` release secret (failing loudly if they can't), and Verify builds never bundle them so snapshot baselines stay on system fonts

Full human-facing setup lives in [Contributing](./CONTRIBUTING.md#local-private-config).

## Coding Patterns

- Prefer existing UIKit, storyboard, presenter, and view-model patterns before introducing new abstractions
- Keep feature behavior in the matching `Putio/Features/<Area>` folder and move only genuinely shared code into `Putio/Common`
- Route put.io API behavior through the local SDK wrapper in `Putio/Common/API` unless a focused system API is the smaller choice
- Use `PutioRealm` helpers for Realm open/write paths and include useful context strings for diagnostics
- Surface unexpected internal failures with `InternalFailurePresenter` instead of silent returns
- Update UI on the main thread, but keep expensive network response parsing, image decoding, and PDF parsing off the main thread
- Make every async loading path finish cleanly on success, failure, cancellation, and back navigation
- Put user-facing copy in localized strings; when Swift copy changes, update `Putio/en.lproj/Localizable.strings`
- Add dependencies only when the repo has no good platform or SDK option

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
