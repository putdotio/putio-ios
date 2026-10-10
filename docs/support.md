# Support messenger

The iOS app runs the Intercom messenger for signed-in users
([#139](https://github.com/putdotio/putio-ios/issues/139)).

| Build setting            | Default | Effect                                       |
| ------------------------ | ------- | -------------------------------------------- |
| `PUTIO_INTERCOM_API_KEY` | empty   | Empty never starts Intercom                  |
| `PUTIO_INTERCOM_APP_ID`  | empty   | Empty never starts Intercom                  |
| `PUTIO_INTERCOM_ENABLED` | `YES`   | Kill switch: any other value never starts it |

[PutioSupportMessenger](../Apps/iOS/Sources/Support/SupportMessenger.swift)
starts Intercom after sign-in, so replies and notifications reach the account,
and logs out when the session ends. It logs in with the account id and the
`user_hash` put.io returns for `platform=ios`, for identity verification, and
sends nothing else. Intercom keeps its user across launches, so a relaunch
reuses the login, and a session that ended while the app was closed is logged
out on the next launch, the one case that starts Intercom while signed out.

Account › Contact us opens the messenger once the login finished. While it is
logging in, or without keys or a hash, it opens an email to support; after a
failed login it retries once, then opens email. Only
[IntercomSupportClient](../Apps/iOS/Sources/Support/IntercomSupportClient.swift)
imports Intercom; `scripts/test.sh` enforces it. The app has no remote push
yet, so Intercom push notifications are not wired.
