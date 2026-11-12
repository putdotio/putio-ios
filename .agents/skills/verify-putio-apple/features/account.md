# Account

A signed-in user manages security, file and privacy preferences, and history,
reaches rating and support links, answers the analytics prompt, and recovers
from a sign-out that did not finish.

## Sub-features

- `sign-out-recovery` shows "Signing out", lands a failed sign-out on the
  welcome, and never restores the account on relaunch; the cleanup finishes
  once the fault clears.
- `session-restore-storage` and `session-restore-check` restore through an
  unreadable credential and an offline session check: retry restores, a failed
  reset keeps the screen, and the secondary action lands on the fresh welcome.
- `security` shows recovery codes, links a device by code, lists apps, clears
  data, and destroys the account.
- `file-preferences` recovers a failed save, resets, keeps settings across
  relaunch, and hides History when it is off.
- `history` pages, opens items, deletes, and follows the History setting.
- `rows` opens and closes every Account row from top to end.
- `rating` opens rating and contact links only after an explicit tap.
- `analytics-prompt` shows saving and failed states, retries, and saves the
  choice once.
- `analytics-prompt-swipe` swipes the prompt away, signs out and in, and
  meets the prompt again.
- `inactive-account`, `inactive-family`, and `active-account` show the
  inactive-account notice on the Files root, clear it after renewal on return
  to the foreground, and show nothing to an active account.

## How to get to it (user POV)

- Account tab; lower rows such as Sign out need a scroll.
- History tab, shown while History is on.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures. `sign-out-recovery` signs in with
  `--putio-harness-sign-out-failure`, which fails revocation and credential
  removal until a launch without it.

- **Sign-out recovery.** Run `--only sign-out-recovery`. The failed sign-out
  and each relaunch show the welcome, never Files. Screenshots:
  `runtime-signing-out`, `runtime-sign-out-failure`.
- **Restore recovery.** Run `--only session-restore-storage,session-restore-check`.
  `--putio-harness-saved-credential-at-launch` seeds the credential;
  `--putio-harness-credential-read-fails-once` and
  `--putio-harness-restore-offline-once` fail the first restore;
  `--putio-harness-restore-seconds` and `--putio-harness-sign-out-seconds` hold
  the progress screens. Screenshots: `runtime-session-storage`,
  `runtime-session-restoring`, `runtime-session-check-failed`.
- **Security.** Run `--only account-security`. Screenshots:
  `runtime-security-recovery-codes`, `runtime-security-apps`,
  `runtime-danger-clear-data`.
- **File preferences.** Run `--only file-preferences`. Screenshots:
  `runtime-file-preferences`, `runtime-file-preferences-refresh`,
  `runtime-privacy-controls`.
- **History.** Run `--only history`. Screenshots: `runtime-history-loaded`,
  `runtime-history-error`, `runtime-history-empty`.
- **Rows.** Run `--only account-rows`. Every navigation row opens its screen
  and goes back; Privacy policy records its URL.
- **Rating.** Run `--only account-rating`. Screenshot: `runtime-account-rating`.
- **Analytics prompt.** Run `--only analytics-prompt`. Screenshots:
  `runtime-analytics-prompt`, `runtime-analytics-prompt-saving`,
  `runtime-analytics-prompt-failed`. Boards: `rd-ios-ses-10-analytics`,
  `rd-ios-ses-17-analytics-saving`, `rd-ios-ses-18-analytics-failed`,
  `rd-ios-ses-25-ipad-analytics`.
- **Inactive account.** Run `--only inactive-account,inactive-family,active-account`.
  `--putio-harness-account-inactive <owner|owner-no-date|family>` picks the
  fixture; `--putio-harness-account-renews-in-background` turns it active when
  the app leaves the foreground. Screenshots: `runtime-inactive-notice`,
  `runtime-inactive-renewed`.

## Gotchas

- Account rows load lazily. Scroll until the row exists before you tap it.
- Sign-out asks "Are you sure?" first (`auth.sign-out-confirm`).
- Session rules live in [session lifecycle](../../../../docs/session.md).
