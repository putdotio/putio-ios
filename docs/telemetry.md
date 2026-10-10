# Telemetry

The iOS app reports crashes and errors to Sentry under the account's
Diagnostics choice and runs the Intercom support messenger for signed-in users
([#139](https://github.com/putdotio/putio-ios/issues/139)).

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
A failed restore that keeps the credential leaves the answer as it was.

Sentry queues envelopes and crash reports under `Caches/io.put.diagnostics`
and uploads them on close and start without running `beforeSend`. Turning
Diagnostics off, or launching with it off, deletes that folder, and a URL
session delegate cancels every upload while it is off.

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

## Support messenger

| Build setting            | Default | Effect                                       |
| ------------------------ | ------- | -------------------------------------------- |
| `PUTIO_INTERCOM_API_KEY` | empty   | Empty never starts Intercom                  |
| `PUTIO_INTERCOM_APP_ID`  | empty   | Empty never starts Intercom                  |
| `PUTIO_INTERCOM_ENABLED` | `YES`   | Kill switch: any other value never starts it |

[PutioSupportMessenger](../Apps/iOS/Sources/Support/SupportMessenger.swift)
starts Intercom after sign-in, so replies and notifications reach the account,
and logs out when the session ends. It logs in with the account id and the
`user_hash` put.io returns for `platform=ios`, for identity verification, and
sends nothing else. Without keys, a hash, or a successful login, Account ›
Contact us opens an email to support instead. Only
[IntercomSupportClient](../Apps/iOS/Sources/Support/IntercomSupportClient.swift)
imports Intercom; `scripts/test.sh` enforces it. The app has no remote push
yet, so Intercom push notifications are not wired.
