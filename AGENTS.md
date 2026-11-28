# Agent Guide

The put.io iOS app that ships on the App Store: UIKit with Swift packages.
Feature code lives in `Putio/Features/<Area>`; code two areas share goes in
`Putio/Common`.

The SwiftUI rewrite of the iOS, watchOS and tvOS apps lives on `next`, with
its own AGENTS.md. PRs for the rewrite target `next`.

## Work in this repository

- Setup, brand fonts, and private config: [CONTRIBUTING](CONTRIBUTING.md#setup).
- Keep checked-in defaults open-source-safe.
- Route put.io API behavior through the SDK wrapper in `Putio/Common/API`.
- Open and write Realm through the `PutioRealm` helpers, with context strings
  for diagnostics.
- Surface unexpected internal failures with `InternalFailurePresenter`.
- Report failures only through `SentryTelemetry.capture(.category, error:)`.
- Send product analytics only through `ProductAnalytics.capture(.event)`. Define
  every event in `AnalyticsEvent` and register its keys and values in
  `AnalyticsAllowlist` ([`AnalyticsEvent.swift`](Putio/Common/Analytics/AnalyticsEvent.swift)).
- Swift copy goes in `Putio/en.lproj/Localizable.strings`; storyboard and xib
  copy goes in the matching `Putio/en.lproj/*.strings` file.
- Add a dependency only when no platform or SDK option fits. Add it as a Swift
  package pinned to an exact version, then run `mise run acknowledgements-sync`.

## Hazards

- **App Store delivery.** `Beta`, `Release`, `Screenshots`, and `Submit` run from
  `main` with production credentials and mutate TestFlight or App Store Connect
  (`Screenshots` applies metadata, version settings, and screenshots unless run
  as a dry run). Dispatch them only when asked ([workflows](.github/workflows)).
- **Baselines.** Record them only with `mise run screenshots-record`, on the
  ephemeral simulator it creates. A device picked with
  `PUTIO_SIMULATOR_ID=<udid>` keeps its own locale.

## Verification

| Change                                | Proof                                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Any behavior change                   | `mise run verify`                                                                                                                                                         |
| Packages or build settings            | `mise run release-launch`; also before dispatching Beta or Release                                                                                                        |
| SDK-backed app flow                   | `mise run e2e-simulator` before live-account checks; pull-request CI doesn't run it                                                                                       |
| Auth, keychain, or signed-in state    | `mise run verify` and `mise run run-simulator`                                                                                                                            |
| Screen layout or copy                 | `mise run screenshots-verify`; `e2e-simulator` skips the screenshot walk                                                                                                  |
| Intentional visual change             | Re-record [visual baselines](CONTRIBUTING.md#visual-baselines); also refresh [App Store images](CONTRIBUTING.md#app-store-images) if a store slot changed                 |
| File previews                         | Smoke-test in a simulator with real image and PDF files                                                                                                                   |
| Performance-sensitive work            | Profile it as [Measure Performance](CONTRIBUTING.md#measure-performance) says; run `mise run verify` and `mise run e2e-simulator`                                         |
| Node tooling, scripts, or workflows   | `mise run verify-scripts-types` and `mise run verify-scripts-tests`                                                                                                       |
| App Store listing or marketing images | `mise run verify-store-images` and `node scripts/app-store.ts check`                                                                                                      |
