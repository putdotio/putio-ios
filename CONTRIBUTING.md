# Contributing

Thanks for contributing to `putio-ios`.

## Setup

Most local work only needs the normal toolchain and the checked-in development defaults.

- Prerequisites:
  - Xcode `26.x`
  - iOS `26.x` simulator runtime
  - [mise](https://mise.jdx.dev) — it pins the toolchain and runs every task in
    this repo
  - Ruby and Node come from `mise.toml` via `mise install`; pnpm arrives with
    `corepack enable`
- Install dependencies:

```bash
mise run bootstrap
```

`mise run bootstrap` starts with a `mise run doctor` preflight that checks your active
Ruby and Node against the `[tools]` pins in `mise.toml`, that pnpm is on PATH
and matches `packageManager`, and your Xcode developer directory, printing
copy-pasteable fixes for each. `mise.toml` is the only place those versions are
written down: `ruby/setup-ruby` reads it in CI and the `Gemfile` reads it via
`ruby file: 'mise.toml'`, so there is no second pin to keep in step.
`mise tasks` lists every task in the repo with a description. It also installs the repo pre-push hook (`.githooks/pre-push` via
`core.hooksPath`), which runs the sub-second `mise run verify-fast` gate before
every push.

Node is repo tooling only — it builds the visual reference gallery and, later,
App Store images. The app itself builds and tests without it, so `mise run verify`
and `mise run e2e-simulator` do not need `pnpm install` to have run.

- Optional private local overrides:
  - copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`
  - keep `Config/Local.xcconfig` out of git
  - checked-in defaults already use the dedicated local dev app identity `io.put.dev`
  - `Config/Local.xcconfig` is for secrets and team settings, not bundle-id overrides

## Local Private Config

Use this path when your work needs signed local builds or private support
integrations.

- Sign in to Infisical and make sure workspace onboarding has granted access to the `frontend` project and Development environment
- Materialize the local config:

```bash
mise run secrets-setup
```

This renders `Config/Local.xcconfig` from the repo-owned Infisical path. Set
the onboarding-provided `PUTIO_IOS_INFISICAL_*` variables in this repo or
worktree shell before running the command. Run `mise run secrets-clean` to remove
the generated file.

### Brand fonts (required)

The licensed GT America and Berkeley Mono files are never committed —
`mise run verify-fast` fails if any font binary is tracked. They are downloaded from
`static.put.io`, the same files the web app already serves to browsers, so **no
credentials are needed**:

```bash
mise run fonts-setup   # download into gitignored Putio/Fonts/
mise run verify-fonts   # report status without writing
```

`Config/BrandFonts.json` lists each file's path under `static.put.io` and its
sha256. The hash is there because these fonts feed pixel-compared snapshot
baselines: if a font is re-uploaded, you get one clear error naming the file
instead of 23 unexplained image diffs. Bump a hash only alongside a deliberate
`mise run screenshots-record`.

`mise run verify-fonts` fails when the directory contradicts the manifest, which
means a stale or hand-placed file. Every CI workflow syncs the fonts before
running verify — no credentials involved — and fails loudly on a bad download,
so neither a system-font build nor a font-less verify can pass silently (see
[Distribution](./docs/DISTRIBUTION.md)).

Verification builds **do** bundle the fonts (`PUTIO_BUNDLE_BRAND_FONTS = YES`
in `Config/Verify.xcconfig`), so baselines are recorded and compared with real
brand typography. They were excluded until 2026-07 and the visual suite was
blind to type as a result — #37, #42, and #43 all changed typography and moved
zero baselines.

The practical consequence: **`mise run verify`, `mise run e2e-simulator`, and
`mise run screenshots-record` all require the fonts.** Run `mise run fonts-setup` first.
`PutioTests/BrandFontTests.swift` pins the contract, so a build that loses the
faces reports a named failure rather than 23 pixel diffs.

Because the fonts need no credentials, every pull request gets the full snapshot
suite — Dependabot and forks included.

- Local signed builds default to:
  - bundle id `io.put.dev`
  - display name `put.io`
  - primary icon `AppIconDev`
- Keep the repo-owned Infisical path aligned with `Config/Local.example.xcconfig`
- CI beta and release builds use the release-secret contract in [Distribution](./docs/DISTRIBUTION.md)

## Run And Validate

- Open the workspace in Xcode:

```bash
open Putio.xcworkspace
```

- Quick local path:

```bash
mise run verify-fast
mise run verify
mise run e2e-simulator
mise run run-simulator
```

- Useful helpers:

```bash
mise run doctor
mise run print-simulator-destination
mise run print-simulator-device
mise run download-ios-platform
mise run verify-icons
plutil -lint Putio/en.lproj/*.strings
```

- Notes:
  - `mise run verify-fast` is the sub-second gate (icon sync check, strings lint, workspace sanity); the pre-push hook runs it automatically
  - `mise run verify-scripts-types` type-checks the repo's TypeScript tooling with `tsc --noEmit`. The scripts run directly — Node strips types, so there is no build step — but stripping is not checking, and an unchecked annotation drifts into a lie. Kept out of `verify-fast` so that gate keeps running without Node; CI runs it in the `verify-tooling` job instead
  - `mise run vref` renders `.vref/index.html` from the committed baselines for design review, and `mise run vref-serve` serves it on `127.0.0.1:4173`. It is deliberately **not** part of `verify-fast`: validating it needs Node and the regenerated copies, and `verify-fast` is a sub-second gate that runs without Node. Baseline/manifest drift is caught when `mise run vref` runs, which today means locally; publishing the gallery, and checking it in CI, is future work in #49

  - `mise run store-screenshots` writes the App Store set to gitignored `dist/store-screenshots/<device>/`, numbered in the order Apple displays them. It copies committed images rather than capturing, and `mise run verify-store-screenshots` validates without writing. Changing the set means editing `Config/StoreScreenshots.json`
  - the two devices get there differently. **iPhone** needs no capture: the pinned simulator's 1320x2868 walk output is already Apple's 6.9" size, so those store images are the ones CI pixel-compares. **iPad** has no walk in that suite, so `mise run store-capture-ipad` records one on demand — the same walk on an ephemeral iPad Pro 13-inch (M5), five marketing screens at 2064x2752, into `PutioUITests/__Captures__/ipad-13/`. The `__Captures__` name is the tell: nothing asserts these, because putting a second device in the pixel-compared suite would exercise the same code paths for roughly double the job time. They are committed anyway so `store-screenshots` needs no capture step, and the image diff on the rendered marketing images is what gets reviewed. Run it after a visual change that affects a store slot; it takes about 2 minutes
  - `mise run verify-store-images` checks the committed marketing images against the baselines and configs they came from, using `Config/StoreImages.lock.json`. It hashes inputs instead of re-rendering, so it needs neither Chromium nor a capture — which is why CI can run it on Linux. If it fails, run `mise run store-images`, review the image diff, and commit the images and the lock together. Prose keys (anything starting with `$`) are excluded from the hashes, so improving a comment does not mark the set stale
  - visual baselines cover reusable components (`PutioTests/__Snapshots__/`, rendered directly in unit tests) and 13 full screens (`PutioUITests/__Snapshots__/`, captured by the e2e walk); the app is dark-only, so baselines capture dark mode only; after an intentional visual change run `mise run screenshots-record` and commit the resulting image diff (GitHub renders before/after in review)
  - `mise run screenshots-record` records **and then asserts against what it wrote**, in one run and on one simulator, so a green exit means the recording is self-consistent — there is no second pass to remember. Scope it when you changed one screen: `mise run screenshots-record -- --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk` takes about a minute against about five for the full set. `--only` takes xcodebuild's `-only-testing:` syntax and its leading test target picks the tier, so the scheme you did not touch is never built. `mise run screenshots-record-components` and `mise run screenshots-record-screens` run one whole tier
  - a scoped run writes a subset, so the baseline-count tripwire is skipped for it; run the full target before committing if you added or removed a snapshot test
  - `mise run verify` uses an unsigned simulator build
  - `mise run verify` and `mise run e2e-simulator` write result bundles to `build/verify.xcresult` and `build/e2e-simulator.xcresult`; CI uploads them as artifacts when a run fails
  - `mise run e2e-simulator` runs fast mocked XCUITests against fixture-backed SDK responses; set `PUTIO_E2E_MOCK_API=1` plus `PUTIO_E2E_FAIL_ROUTES` (comma-separated `METHOD /path` keys) in a test's launch environment to force 500 responses for failure-path coverage
  - `PUTIO_E2E_MOCK_API=1` also holds back app behavior that a screenshot cannot capture deterministically: the downloads tutorial parks its clip on a fixed frame instead of playing it, the files nav bar omits the Google Cast button (it appears only when the Cast SDK finds a receiver, so it depends on what is on the LAN — a maintainer's Mac finds one, CI does not), and the login screen does not auto-start web auth (whose system consent alert would otherwise sit above the simulator). Tapping `Log in` still starts the flow
  - `mise run verify` and `mise run e2e-simulator` each create an ephemeral simulator (pinned status bar and `en_US` locale, so the clock and number formats do not drift between a maintainer's Mac and CI) and delete it on exit, so parallel worktrees and agents never collide; set `PUTIO_SIMULATOR_ID=<udid>` to reuse a specific device instead — note that a reused device keeps its own locale, so baselines should be recorded on the ephemeral one
  - GitHub Actions exposes `E2E Simulator` as a manual workflow for PRs or SDK-backed flow changes that need simulator confidence, and runs it weekly against `main` (Mondays 06:00 UTC)
  - `mise run run-simulator` uses a normal signed Simulator build so auth and keychain persistence behave like a real interactive run
  - the simulator device is pinned to **iPhone 17 Pro Max** on iOS `26.0+` (`scripts/simctl-iphone-device-id.sh`); baselines are pixel-compared, so an unpinned device made their dimensions depend on which simulators a machine had installed. 1320x2868 is also Apple's required 6.9" App Store screenshot size
  - when auth, keychain, or signed-in persistence changes, use both `mise run verify` and `mise run run-simulator`

## Targeted Regression Checks

- Focused xcodebuild runs are fine while iterating, but treat `mise run verify` as the repo gate before handoff
- Useful targeted suites after recent cleanup work:
  - `PutioTests/APIErrorLocalizerTests`
  - `PutioTests/ErrorPresentationTests`
  - `PutioTests/NavigationLocalizationTests`
  - `PutioTests/PutioRealmTests`

## Configuration

- Private support integrations are disabled by default in `Putio/Info.plist`
- OAuth client id stays configured in local builds so browser-based login still works
- Runtime app config flows through:
  - `Config/Shared.xcconfig`
  - optional `Config/Local.xcconfig`
  - `Info.plist` placeholders
- Fastlane passes the same `PUTIO_*` values through Xcode during beta archive builds
- User-facing copy now has an English base under `Putio/en.lproj`
  - when changing copy in Swift, update `Putio/en.lproj/Localizable.strings`
  - when changing storyboard or xib copy, update the matching `Putio/en.lproj/*.strings` file
- Product UI glyphs use the pinned Phosphor asset workflow in [Icon system](./docs/ICONS.md)
  - edit `Config/PhosphorIcons.json` and run `mise run icons-sync` when adding or updating icons
  - do not hand-edit generated files under `Putio/Assets.xcassets/Phosphor`
- Keep repo-stored configuration open-source-safe
  - keep tokens, signing keys, API key files, and private release metadata out of commits

## CI And Delivery

- See [Distribution](./docs/DISTRIBUTION.md) for:
  - workflow roles
  - CI bootstrap behavior
  - fastlane release contract
  - TestFlight distribution notes
  - signing and App Store Connect gotchas

## Known Debt

- The app is still a legacy UIKit and storyboard codebase
- Some large feature areas, especially Files and Settings, have been split into smaller units but still carry historical complexity
- English localization is extracted, but additional locale coverage is still follow-up work

## Good First Contributions

- Add focused unit coverage around pure logic and model parsing
- Continue shrinking legacy UIKit hotspots without changing behavior
- Improve light mode and visual polish without changing release infrastructure
- Tackle localization and copy consistency in isolated follow-up pull requests

## Pull Requests

- Keep changes focused and explicit
- Add or update verification when behavior changes
- Include the most helpful review evidence for the kind of change you made
  - screenshots or screen recordings for UI, layout, animation, onboarding, or copy changes
  - sanity checks for risky or user-visible flows
  - before and after benchmark numbers for performance-sensitive changes
  - risk, rollout, or follow-up notes when touching auth, persistence, release flow, or external integrations
- Update docs when setup, CI, or release expectations change
- Prefer follow-up pull requests over mixing unrelated cleanup into the same branch
