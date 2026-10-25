# Agent Guide

The put.io iOS app that ships on the App Store: UIKit with CocoaPods. Feature
code lives in `Putio/Features/<Area>`; only genuinely shared code goes in
`Putio/Common`.

## Work in this repository

- A fresh worktree needs `mise run bootstrap` and `mise run fonts-setup`;
  snapshot assertions fail without the [brand fonts](CONTRIBUTING.md#brand-fonts).
  Bump a `Config/BrandFonts.json` hash only alongside a re-record.
- Run `mise run secrets-setup` only for signed local builds or private support
  integrations ([Local Private Config](CONTRIBUTING.md#local-private-config)).
  Keep checked-in defaults open-source-safe.
- Ruby and Node are pinned once, in the `[tools]` table of [mise.toml](mise.toml),
  and pnpm by `packageManager` in `package.json`; change versions only there.
  Node is repo tooling only: type-check its scripts with
  `mise run verify-scripts-types`.
- Build on the existing UIKit, storyboard, presenter, and view-model patterns.
- Route put.io API behavior through the SDK wrapper in `Putio/Common/API`.
- Open and write Realm through the `PutioRealm` helpers, with context strings
  for diagnostics.
- Surface unexpected internal failures with `InternalFailurePresenter`.
- Report failures only as `SentryTelemetry.capture(.category, error:)`; its
  `beforeSend` rebuilds every event from `SentryTelemetry.allowlisted`. Sentry
  runs only while the account's `diagnostics_enabled` is on, and a stored
  opt-out holds before the account loads.
- Send product analytics only as `ProductAnalytics.capture(.event)`. Add an
  `AnalyticsEvent` case only for an event the Analytics event contract lists,
  and add its keys and values to `AnalyticsAllowlist`. PostHog runs only for a
  signed-in account whose `product_analytics_enabled` is on; sign-out, opt-out,
  a 401, or an account switch closes it and deletes its storage.
- The inactive-account notice keys on `account_status`; `account_active`
  arrives as `true` or `null`.
- Update UI on the main thread; parse network responses, decode images, and
  parse PDFs off it.
- Every async loading path finishes cleanly on success, failure, cancellation,
  and back navigation.
- User-facing copy goes in `Putio/en.lproj/Localizable.strings`.
- Add a dependency only when no platform or SDK option fits.

## Hazards

- **App Store delivery.** Beta, Release, Screenshots, and Submit dispatch from
  `main` with production credentials: Beta emails external testers, Release
  uploads to App Store Connect, Screenshots replaces the live listing images
  unless it runs as a dry run, and Submit sends a build to App Review. Dispatch
  them only when asked ([workflows](.github/workflows)).
- **Simulators.** `verify` and `e2e-simulator` each create and delete an
  ephemeral simulator. `PUTIO_SIMULATOR_ID=<udid>` targets a device but keeps
  its own locale, so record baselines on the ephemeral one.

## Verification

| Change                             | Proof                                                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Any behavior change                | `mise run verify`                                                                                                         |
| SDK-backed app flow                | `mise run e2e-simulator` before live-account checks; pull-request CI doesn't run it                                       |
| Auth, keychain, or signed-in state | `mise run verify` and `mise run run-simulator`                                                                            |
| Intentional visual change          | Re-record [visual baselines](CONTRIBUTING.md#visual-baselines), then [App Store images](CONTRIBUTING.md#app-store-images) |
| File previews                      | Smoke-test in a simulator with real image and PDF files                                                                   |
| Performance-sensitive work         | Before and after `mise run perf` on one simulator ([Measure Performance](CONTRIBUTING.md#measure-performance))            |
