# Agent Guide

- Native iOS app repository for put.io
- Stack: UIKit, CocoaPods, Bundler-managed Ruby, and pnpm-managed Node for repo tooling (not app code)
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

## Worktrees

`.worktreeinclude` carries local env, Bundler, Xcode, and font config into
Codex and Claude worktrees. Run `make bootstrap`; use `make secrets-setup` or
`make fonts-setup` only when a required local file is missing.

## Workflow

- Keep checked-in defaults open-source-safe
- Private service keys stay out of git
- Update docs when setup, validation, or release expectations change
- Keep branches focused; prefer follow-up PRs over unrelated cleanup
- Use [Contributing](./CONTRIBUTING.md) for setup, local validation, teammate-only private config, and localization workflow
- Use [Distribution](./docs/DISTRIBUTION.md) for CI, TestFlight, and release-promotion rules

## Local Environment

Xcode + Fastlane carry their own config and signing flow; this repo does not use a `.envrc` / `secrets` task-runner pattern.

- A fresh worktree needs `make bootstrap` and `make fonts-setup` — snapshot assertions require the licensed faces since baselines are recorded with them. Nothing else needs local secrets
- `make doctor` (also a `bootstrap` preflight) checks the active Ruby against `.ruby-version`, Node against `.node-version`, that pnpm is on PATH, and the Xcode developer directory, and prints copy-pasteable fixes for each
- Node is repo tooling only — the app builds and tests with no Node involvement, so `verify`, `e2e-simulator`, and the archive lanes never touch it. `node_modules/` is gitignored and reinstalled by `make bootstrap`, so it is deliberately absent from `.worktreeinclude`
- `make bootstrap` installs the repo pre-push hook (`.githooks/pre-push`), which runs `make verify-fast` — icon sync check, localized strings lint, and workspace sanity — in under a second
- `make verify` and `make e2e-simulator` write test result bundles to `build/verify.xcresult` and `build/e2e-simulator.xcresult`; CI uploads them as artifacts on failure
- `make verify` and `make e2e-simulator` each create an ephemeral simulator (pinned status bar and `en_US` locale, so the clock and number formats match between a maintainer's Mac and CI) and delete it on exit, so parallel worktrees never collide; set `PUTIO_SIMULATOR_ID=<udid>` to target a specific device instead (`make run-simulator` keeps using the shared visible simulator)
- Visual baselines live in two tiers, both asserted with SnapshotTesting (perceptual tolerance): component-level snapshots in `PutioTests/__Snapshots__/` (buttons, cells, state views) and full-screen walk captures in `PutioUITests/__Snapshots__/` (12 screens); the app is dark-only, so both tiers capture dark mode only. Both are recorded on a pinned iPhone 17 Pro Max (1320x2868) with the brand faces bundled. After an intentional visual change run `make screenshots-record` (re-records both tiers, fails on partial runs), review the image diff, and commit the new baselines
- E2e also runs weekly in CI (Mondays 06:00 UTC) via `.github/workflows/e2e-simulator.yml`
- `make vref` builds a browsable gallery of the committed baselines into gitignored `.vref/screenshots/` and `.vref/index.html`; only `.vref/manifest.json` is committed, so the copies cannot drift from the images CI pixel-compares. `make vref-serve` serves it locally. Curated titles, tags and notes live in the manifest and survive a rebuild; a baseline with no entry, or an entry with no baseline, fails the sync by name. See [.vref/README.md](./.vref/README.md)

- `make store-screenshots` assembles the App Store set into gitignored `dist/store-screenshots/`. There is no separate capture for iPhone: the walk is pinned to iPhone 17 Pro Max, whose 1320x2868 output is exactly Apple's 6.9 inch size, so the store set is a selection over baselines CI already pixel-compares. `Config/StoreScreenshots.json` holds the slot order; the script fails if a baseline is missing, the wrong size, or the slots have gaps. iPad is not covered yet — it needs a real capture lane
- `make store-images` frames those into finished marketing images in `fastlane/screenshots/en-US/` — brand-yellow field, bold caption, rounded black device — using Playwright with tokens from `@putdotio/design` and the bundled GT America. Captions live in `Config/StoreCaptions.json`. Output is committed so it is reviewed as an image diff; rendering refuses to run without the brand fonts rather than shipping system-font typography
- Use `make secrets-setup` only for signed local builds or private support integrations; it writes ignored `Config/Local.xcconfig` from maintainer-supplied `PUTIO_IOS_INFISICAL_*` values
- `make fonts-setup` downloads the licensed brand fonts from `static.put.io` into gitignored `Putio/Fonts/` — the same files the web app serves to browsers, so no credentials, no private repository, and no `gh`. `Config/BrandFonts.json` carries each path and sha256; the hash guards pixel-compared baselines against a silently re-uploaded font. It is **required**, not optional: baselines are recorded with the faces bundled (`PUTIO_BUNDLE_BRAND_FONTS = YES`), so `make verify`, `make e2e-simulator`, and `make screenshots-record` all fail their snapshot assertions without them. Every CI workflow syncs the fonts before running verify, so pull requests — including Dependabot and forks — get full snapshot coverage

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
