# Telemetry

The iOS app reports crashes and errors to Sentry under the account's
Diagnostics choice. The privacy contract is [putdotio/support#95](https://github.com/putdotio/support/issues/95); this page
covers how the app keeps it.

## Diagnostics

| Build setting              | Default                                                                            | Effect                                                                 |
| -------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `PUTIO_SENTRY_DSN`         | empty                                                                              | Empty or malformed reports nothing. Events post through `relay.put.io` |
| `PUTIO_SENTRY_ENABLED`     | `YES`                                                                              | Kill switch: any other value reports nothing                           |
| `PUTIO_SENTRY_ENVIRONMENT` | `development` in Debug, `production` in Release (`nightly` for the nightly flavor) | Sentry environment                                                     |

The release is `<bundle id>@<version>+<build>`.
[SentryConfiguration](../Apps/iOS/Sources/Telemetry/SentryConfiguration.swift)
reads these from Info.plist and swaps the DSN host for `relay.put.io`, which
forwards only allowlisted project ids.

[PutioDiagnosticsConsent](../Packages/PutioCore/Sources/PutioCore/Account/DiagnosticsConsent.swift)
follows `diagnostics_enabled`: signed out or not yet answered counts as on, and
the last account answer is kept so a cold launch honors an opt-out before the
session restores. [PutioDiagnostics](../Apps/iOS/Sources/Telemetry/PutioDiagnostics.swift)
starts Sentry at launch and on every session change, including the Account ›
Privacy toggle, so turning Diagnostics off closes the SDK in the running app.

## Redaction

[SentryTelemetry](../Apps/iOS/Sources/Telemetry/SentryTelemetry.swift) is the
only file that imports Sentry; `scripts/test.sh` fails on an import anywhere
else in the apps. Its `beforeSend` and `beforeBreadcrumb` drop everything while
diagnostics are off and pass the rest through
[TelemetryRedaction](../Apps/iOS/Sources/Telemetry/TelemetryRedaction.swift),
shared with the legacy app on `main` ([#150](https://github.com/putdotio/putio-ios/issues/150)). Report failures as
`TelemetryFailure` categories, never as raw errors or messages.
`SentryTelemetryTests` fails when a Sentry upgrade adds an event field the
boundary has not reviewed.
