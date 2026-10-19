# Agent Guide

- Native iOS app repository for put.io
- Stack: UIKit, CocoaPods, Bundler-managed Ruby, and pnpm-managed Node for repo tooling (not app code)
- App code lives under `Putio/Features` and shared helpers live under `Putio/Common`
- Tests live under `PutioTests`

## Start Here

- [Overview](./README.md)
- [Contributing](./CONTRIBUTING.md)
- [Distribution](./docs/distribution.md)
- [Security](./SECURITY.md)

## Core Commands

- `mise run doctor`
- `mise run bootstrap`
- `mise run verify-fast`
- `mise run verify`
- `mise run e2e-simulator`
- `mise run run-simulator`
- `mise run perf`
- `mise run dead-code` (Periphery, configured in `.periphery.yml`; local only)

`mise tasks` lists every task; [mise.toml](./mise.toml) owns their definitions.

## Worktrees

`.worktreeinclude` carries local env, Bundler, Xcode, and font config into
Codex and Claude worktrees. Run `mise run bootstrap`; use `mise run secrets-setup` or
`mise run fonts-setup` only when a required local file is missing.

## Workflow

- Keep checked-in defaults open-source-safe
- Private service keys stay out of git
- Update docs when setup, validation, or release expectations change
- Name supporting docs in lowercase kebab-case (`docs/distribution.md`); only tool and convention entrypoints such as `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, and `.github` templates keep uppercase
- Keep branches focused; prefer follow-up PRs over unrelated cleanup
- Use [Contributing](./CONTRIBUTING.md) for setup, local validation, teammate-only private config, and localization workflow
- Use [Distribution](./docs/distribution.md) for CI, TestFlight, and release-promotion rules

## Local Environment

- A fresh worktree needs `mise run bootstrap` and `mise run fonts-setup`. The fonts are required: `Config/Verify.xcconfig` bundles them, so `verify`, `e2e-simulator`, and `screenshots-record` fail their snapshot assertions without them. `Config/BrandFonts.json` pins each file's sha256; bump a hash only alongside a re-record
- `mise run secrets-setup` is only for signed local builds or private support integrations ([Local Private Config](./CONTRIBUTING.md#local-private-config))
- Ruby and Node are pinned once, in the `[tools]` table of [mise.toml](./mise.toml); CI and the `Gemfile` read that pin, and pnpm is pinned by `packageManager` in `package.json`. Don't add a second pin
- Node is repo tooling only; `verify`, `e2e-simulator`, and the archive lanes never need it. Scripts are TypeScript that Node runs without a build step, so type-check them with `mise run verify-scripts-types`; it stays out of `verify-fast`, which needs no Node
- The pre-push hook (`.githooks/pre-push`, installed by bootstrap) runs `mise run verify-fast`; [scripts/verify-fast.sh](./scripts/verify-fast.sh) lists what it checks
- `verify` and `e2e-simulator` each create and delete an ephemeral simulator, so parallel worktrees never collide, and write `build/verify.xcresult` or `build/e2e-simulator.xcresult`. `PUTIO_SIMULATOR_ID=<udid>` targets a specific device, but it keeps its own locale, so record baselines on the ephemeral one
- Visual baselines: components in `PutioTests/__Snapshots__/`, full screens in `PutioUITests/__Snapshots__/`, dark mode only, on a pinned iPhone 17 Pro Max. After an intentional visual change run `mise run screenshots-record`, review the image diff, and commit the baselines. Scope one screen with `-- --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk` (about 1 minute instead of 5)
- `main` is the default branch, so [E2E Simulator](./.github/workflows/e2e-simulator.yml) runs against `main` every Monday at 06:00 UTC and can be dispatched with `gh workflow run e2e-simulator.yml --ref main`. It doesn't run on pull requests, so run `mise run e2e-simulator` yourself before handing off
- `mise run vref` builds the local baseline gallery; see [.vref/README.md](./.vref/README.md)
- App Store images are generated from the baselines. `store-screenshots` selects iPhone slots from `Config/StoreScreenshots.json`; `store-capture-ipad` records the unasserted iPad set into `PutioUITests/__Captures__/ipad-13/`; `store-images` frames both into committed `fastlane/screenshots/en-US/` with captions from `Config/StoreCaptions.json` and writes `Config/StoreImages.lock.json`. Commit images and lock together; `verify-store-images` fails when a baseline changed without a re-render

## Coding Patterns

- Prefer existing UIKit, storyboard, presenter, and view-model patterns before introducing new abstractions
- Keep feature behavior in the matching `Putio/Features/<Area>` folder and move only genuinely shared code into `Putio/Common`
- Route put.io API behavior through the local SDK wrapper in `Putio/Common/API` unless a focused system API is the smaller choice
- Use `PutioRealm` helpers for Realm open/write paths and include useful context strings for diagnostics
- Surface unexpected internal failures with `InternalFailurePresenter` instead of silent returns
- Report failures to Sentry only as `SentryTelemetry.capture(.category, error:)`. Breadcrumbs and failed-request capture are off, and `beforeSend` rebuilds every event, crashes included, from the allowlist in `SentryTelemetry.allowlisted`. `verify-fast` rejects `import Sentry` outside `Putio/Common/Telemetry`
- Sentry runs only while the account's `diagnostics_enabled` is on. Launch applies the last answer `SentryTelemetry.update(diagnosticsEnabled:)` stored, so an opt-out holds before the account loads; signed out or never answered is on. The Account › Privacy controls Diagnostics switch applies its answer as soon as put.io saves it, without a relaunch. Switching off drops events, cancels uploads, and deletes the app-owned Sentry cache
- Send product analytics only as `ProductAnalytics.capture(.event)` with an `AnalyticsEvent` case; add a case only for an event the Analytics event contract lists, and list its keys and values in `AnalyticsAllowlist` too. PostHog starts only in the App Store bundle with the Release token, for a signed-in account whose `product_analytics_enabled` is on, and never before that account loads. Its `beforeSend` keeps only the allowlist. Turning the control off, signing out, a 401 from put.io, or an account switch closes the SDK and deletes its storage; nothing calls `reset()`. `verify-fast` rejects `import PostHog` outside `Putio/Common/Analytics`, and a Release token that is missing or not a `phc_` project token
- Update UI on the main thread, but keep expensive network response parsing, image decoding, and PDF parsing off the main thread
- Make every async loading path finish cleanly on success, failure, cancellation, and back navigation
- Put user-facing copy in localized strings; when Swift copy changes, update `Putio/en.lproj/Localizable.strings`
- Add dependencies only when the repo has no good platform or SDK option

## Verification Matrix

- Any behavior change: run `mise run verify`
- SDK-backed app flow: run `mise run e2e-simulator` before live-account checks
- When auth, keychain, or signed-in persistence changes, run both `mise run verify` and `mise run run-simulator`
- When user-facing copy changes, update the matching files under `Putio/en.lproj` and lint them with `plutil -lint Putio/en.lproj/*.strings`
- When preparing a PR or handoff, include the most helpful evidence for review: visual aids for UI changes, sanity checks for risky flows, and before or after benchmarks for performance-sensitive work, measured with `mise run perf` on one simulator ([Measure Performance](./CONTRIBUTING.md#measure-performance))

## Regression Hotspots

- Auth callback handling, post-login persistence, and user-facing recovery copy are covered by `PutioTests/ErrorPresentationTests.swift` and `PutioTests/PutioRealmTests.swift`
- Files action labels and related localization expectations are covered by `PutioTests/NavigationLocalizationTests.swift`
- The Sentry allowlist is covered by `PutioTests/SentryTelemetryTests.swift`, which fails if a URL, token, file name, or title in any field outside the allowlist reaches the upload
- The PostHog gate and allowlist are covered by `PutioTests/ProductAnalyticsTests.swift`, which runs the real SDK against a recording URL protocol and fails if a forbidden field reaches `/batch`, or a request leaves before sign-in, with the control unset or off, or after an opt-out
- Privacy controls and the one-time product-analytics prompt are covered by `PutioTests/ProductAnalyticsPromptTests.swift` (who is asked, and the setting-then-answer write order), `SettingsViewModelTests` in `PutioTests/PutioKeychainTests.swift` (switch saves, failures, and an account read from before a save or a foreground refresh), and `PutioUITests/PrivacyControlsUITests.swift`. The mocked config has already answered the prompt; `PUTIO_E2E_PRODUCT_ANALYTICS_UNANSWERED=1` serves one that has not
- The inactive-account notice keys on `account_status`, never `account_active`, which the API sends as `true` or `null`; `PutioTests/AccountNoticeTests.swift` covers its states, day count and its redraw when the day changes, banner height at the largest text size, and the audio queue stopping at the last download, and `PutioUITests/InactiveAccountUITests.swift` the banner and the playback gate
- File preview changes should be smoke-tested in Simulator with real image and PDF files when possible
