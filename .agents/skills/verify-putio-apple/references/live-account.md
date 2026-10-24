# Live account

Seeded journeys need no account or secret. Live checks sign in to the shared
`devs-auto` put.io CLI profile, which the web, Android, and TV harnesses also
use.

```bash
mise run harness -- auth-status --output json
mise run harness -- live-fixture --output json
mise run harness -- journey --platform ios --scenario live-files-browser
mise run harness -- journey --platform tvos --scenario live-device-sign-in
```

## Profile and fixture

[LiveAdapters](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/LiveAdapters.swift)
requires the `devs-auto` profile. It removes an ambient `PUTIO_CLI_TOKEN` from
its put.io child processes and checks the profile's authentication before any
write. If that check fails, run `putio auth login --profile devs-auto`.

`live-fixture` reuses the `putio-ios-harness` root folder and its
`live-fixture.png` image, uploaded from the
[preview fixtures](../../../../Tests/HarnessMedia/previews). It validates each
missing write with `--dry-run` first. Both stay in place for later runs.

## Live journeys

The Debug app launches with the `live` scenario against put.io and keeps its
token under the harness keychain item. On iOS, Sign in starts the device-code
flow instead of the web login; Release builds leave that path out.

1. The app writes the code it shows to its data container.
2. The harness approves the code with `putio auth approve`, which links a new
   grant for the app to the account. The token stays inside the app.
3. iOS opens the fixture folder and previews the image. Neither journey writes
   files.
4. The journey signs out through the account screen.

## Revocation

- Signing out revokes the run's grant. The live token store keeps a
  pending-revocation copy until put.io revokes or rejects the token.
- After any approval, even in a failed journey, the harness relaunches the app
  with `--putio-harness-live-sign-out` to restore and sign out that token, up to
  three attempts.
- A missing token is not proof. The journey passes only when put.io revoked or
  rejected the token.
- SIGINT or SIGTERM cancels an approval that has not started, or revokes once
  after it finishes, before the simulator is deleted.
- If an approval is interrupted before the app saves its token, nothing in the
  simulator can revoke the grant. The harness reports that the grant may be live
  and names the manual revocation.

## Captures

The CLI cannot list authorized apps. The iOS journey captures Account >
Security > "Where you're signed in" while signed in. put.io lists grants per
app, not per session, so that screen cannot show whether one run's token is
gone; the cleanup result is the per-run evidence. The capture shows every app on
the shared account, so review it before you share it.
