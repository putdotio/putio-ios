# Agent Guide

The put.io iOS app that ships on the App Store: UIKit with CocoaPods. Feature
code lives in `Putio/Features/<Area>`; only genuinely shared code goes in
`Putio/Common`.

## Work in this repository

- A fresh worktree needs `mise run bootstrap` and `mise run fonts-setup`;
  snapshot assertions fail without the [brand fonts](CONTRIBUTING.md#brand-fonts).
- Run `mise run secrets-setup` only for signed local builds or private support
  integrations ([Local Private Config](CONTRIBUTING.md#local-private-config)).
  Keep checked-in defaults open-source-safe.
- Change Ruby and Node versions only in the `[tools]` table of
  [mise.toml](mise.toml), and pnpm only in `packageManager` in `package.json`.
  Node is repo tooling only; `mise run verify-scripts-types` checks it.
- Route put.io API behavior through the SDK wrapper in `Putio/Common/API`.
- Open and write Realm through the `PutioRealm` helpers, with context strings
  for diagnostics.
- Surface unexpected internal failures with `InternalFailurePresenter`.
- Report failures only through `SentryTelemetry.capture(.category, error:)`.
- Send product analytics only through `ProductAnalytics.capture(.event)`. Add
  an `AnalyticsEvent` case only for an event the Analytics event contract
  lists, and add its keys and values to `AnalyticsAllowlist`.
- Every async loading path finishes cleanly on success, failure, cancellation,
  and back navigation.
- Swift copy goes in `Putio/en.lproj/Localizable.strings`; storyboard and xib
  copy goes in the matching `Putio/en.lproj/*.strings` file.
- Add a dependency only when no platform or SDK option fits.

## Hazards

- **App Store delivery.** Beta, Release, Screenshots, and Submit dispatch from
  `main` with production credentials: Beta emails external testers, Release
  uploads to App Store Connect, Screenshots replaces the live listing images
  unless it runs as a dry run, and Submit sends a build to App Review. Dispatch
  them only when asked ([workflows](.github/workflows)).
- **Baselines.** Record them only on the ephemeral simulator that `verify` and
  `e2e-simulator` create. A device picked with `PUTIO_SIMULATOR_ID=<udid>`
  keeps its own locale.

## Verification

| Change                             | Proof                                                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Any behavior change                | `mise run verify`                                                                                                         |
| SDK-backed app flow                | `mise run e2e-simulator` before live-account checks; pull-request CI doesn't run it                                       |
| Auth, keychain, or signed-in state | `mise run verify` and `mise run run-simulator`                                                                            |
| Intentional visual change          | Re-record [visual baselines](CONTRIBUTING.md#visual-baselines), then [App Store images](CONTRIBUTING.md#app-store-images) |
| File previews                      | Smoke-test in a simulator with real image and PDF files                                                                   |
| Performance-sensitive work         | Before and after `mise run perf` on one simulator ([Measure Performance](CONTRIBUTING.md#measure-performance))            |
