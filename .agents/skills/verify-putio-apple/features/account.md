# Account

A signed-in user manages security, file and privacy preferences, and history,
reaches rating and support links, answers the analytics prompt, and recovers
from a sign-out that did not finish.

## Sub-features

- `sign-out-recovery` shows "Signing out", lands a failed sign-out on the
  welcome, and never restores the account on relaunch; the cleanup finishes
  once the fault clears.
- `sign-out-downloads` keeps a download through sign-out and back, removes it
  with "Sign out and remove downloads", and dismisses the dialog unchanged.
- `session-restore-storage` and `session-restore-check` restore through an
  unreadable credential and an offline session check: retry restores, a failed
  reset keeps the screen, and the secondary action lands on the fresh welcome.
- `security` links a device by code, lists apps, and clears data.
- `browser-handoffs` opens Two-factor authentication and Destroy account in
  the browser and refreshes the two-factor value on return;
  `destroyed-account` lands on the welcome when the account is gone on return.
- `file-preferences` recovers a failed save, resets, keeps settings across
  relaunch, and hides History when it is off.
- `privacy-controls` reverts a failed Privacy controls switch with a toast and
  keeps both switches across relaunch.
- `history` pages, opens items, deletes, and follows the History setting.
- `rows` opens and closes every Account row from top to end.
- `settings-states` shows settings loading and failed, retries, and reverts a
  failed save with a toast, online and offline.
- `rating` opens rating and contact links only after an explicit tap.
- `analytics-prompt` shows saving and failed states, retries, and saves the
  choice once.
- `analytics-prompt-swipe` swipes the prompt away, signs out and in, and
  meets the prompt again.
- `inactive-account`, `inactive-family`, `inactive-no-date`, and
  `active-account` show the inactive-account notice on the Files root and
  Account, clear it after renewal on return to the foreground, and show
  nothing to an active account.
- `storage-full` shows the full storage bar and line on Account.
- `public-links`, `public-links-slow`, and `public-links-failed` list
  exclusive links, copy, share, and revoke them by menu and swipe, survive a
  failed revoke, and leave nothing behind when the list is left mid-load.

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
- **Sign-out dialog.** Run `--only sign-out-downloads`. Screenshots:
  `runtime-sign-out-downloads`, `runtime-sign-out-no-downloads`. Boards:
  `rd-ios-ses-08-sign-out`, `rd-ios-ses-16-sign-out-no-downloads`,
  `rd-ios-ses-24-ipad-sign-out`.
- **Restore recovery.** Run `--only session-restore-storage,session-restore-check`.
  `--putio-harness-saved-credential-at-launch` seeds the credential;
  `--putio-harness-credential-read-fails-once` and
  `--putio-harness-restore-offline-once` fail the first restore;
  `--putio-harness-restore-seconds` and `--putio-harness-sign-out-seconds` hold
  the progress screens. Screenshots: `runtime-session-storage`,
  `runtime-session-restoring`, `runtime-session-check-failed`.
- **Security.** Run `--only account-security`. Screenshot:
  `runtime-security-apps`. Under `--putio-harness-account-security`, the
  `harness.account-requests` element lists each revoke, device link and
  clear the app sent, one `METHOD path body` line each; assert it rather than
  the UI alone.
- **Clear your data.** Run `--only clear-data,clear-data-leave`. The first
  clear fails once; `--putio-harness-clear-data <hold|accept|slow>` holds,
  accepts or delays it instead. Screenshots: `runtime-danger-clear-failed`,
  `runtime-danger-clear-data`. Boards: `rd-ios-acc-15-clear`,
  `rd-ios-acc-16-clear-confirm`, `rd-ios-acc-53-clear-none` to
  `rd-ios-acc-56-clear-failed`.
- **Browser handoffs.** Run `--only browser-handoffs,destroyed-account`.
  `--putio-harness-rating-link` records opened URLs.
  `--putio-harness-two-factor-on` seeds two-factor on;
  `--putio-harness-two-factor-flips-in-background` flips it;
  `--putio-harness-account-destroyed-in-background` rejects the token after
  the app leaves the foreground. Boards: `rd-ios-acc-17-destroy`,
  `rd-ios-acc-22-account-security`, `rd-ios-acc-43-two-factor-off`.
- **Link a device.** `--only account-security` links a seeded code and
  `--only link-device-cancel` leaves mid-link.
  `--putio-harness-link-device <hold|accept>` holds or accepts the board code
  `X7K2QM`; without it the code is unknown. Boards:
  `rd-ios-acc-49-link-device` to `rd-ios-acc-52-link-device-linked`.
- **Logged-in apps.** Run `--only sign-out-other-apps`. The seeded Apple TV
  revoke fails once. Screenshots: `runtime-security-sign-out-others-partial`,
  `runtime-security-sign-out-others-done`. Never run it on the live account: it
  signs out the shared web, Android and TV sessions.
- **File preferences.** Run `--only file-preferences`. Screenshots:
  `runtime-file-preferences`, `runtime-file-preferences-refresh`.
- **Privacy controls.** Run `--only privacy-controls`. Screenshots:
  `runtime-privacy-save-failed`, `runtime-privacy-controls`.
- **History.** Run `--only history`. Screenshots: `runtime-history-loaded`,
  `runtime-history-error`, `runtime-history-navigation-blocked`,
  `runtime-history-empty`. `--putio-harness-history-board` seeds the board's
  feed for `rd-ios-hist-01-list`.
- **Rows.** Run `--only account-rows`. Every navigation row opens its screen
  and goes back; Two-factor authentication and Privacy policy record their
  URLs.
- **Settings states.** Run `--only account-settings-loading,account-settings-states`.
  `--putio-harness-account-settings slow-load` holds the settings load;
  `fail-load` fails it once. Under either, autoplay's first save fails and its
  second is offline. Screenshots: `runtime-account-settings-loading`,
  `runtime-account-settings-failed`, `runtime-account-save-failed-unavailable`,
  `runtime-account-save-failed-offline`.
- **Rating.** Run `--only account-rating`. Screenshot: `runtime-account-rating`.
- **App info and licenses.** Run `--only app-info`. Copy for support must put
  exactly five anonymous lines on the pasteboard; Open source licenses must list
  the app plus every package in `Apps/iOS/Generated/OpenSourceLicenses.json`.
  Screenshots: `runtime-app-info-copied`, `runtime-open-source-licenses`.
  Boards: `rd-ios-acc-09-app-info`, `rd-ios-acc-34-app-info-copied`,
  `rd-ios-acc-10-licenses`.
- **Analytics prompt.** Run `--only analytics-prompt`. Screenshots:
  `runtime-analytics-prompt`, `runtime-analytics-prompt-saving`,
  `runtime-analytics-prompt-failed`. Boards: `rd-ios-ses-10-analytics`,
  `rd-ios-ses-17-analytics-saving`, `rd-ios-ses-18-analytics-failed`,
  `rd-ios-ses-25-ipad-analytics`.
- **Inactive account and full storage.** Run
  `--only inactive-account,inactive-family,inactive-no-date,active-account,storage-full`.
  `--putio-harness-account-inactive <owner|owner-no-date|family>` picks the
  fixture; `--putio-harness-account-renews-in-background` turns it active when
  the app leaves the foreground; `--putio-harness-account-storage-full` fills
  the disk. Screenshots: `runtime-inactive-notice`,
  `runtime-inactive-account-tab`, `runtime-inactive-renewed`,
  `runtime-storage-full`. Boards: `rd-ios-acc-28-storage-full`,
  `rd-ios-acc-29-inactive`, `rd-ios-acc-30-inactive-family`.

- **Exclusive links.** Run `--only public-links,public-links-slow,public-links-failed`.
  `--putio-harness-public-links <ready|journey|slow|failing|empty>` seeds the
  list; without it the list is empty. `journey` adds a link without an expiry,
  adds one more after the first load for pull to refresh, and fails the first
  revoke of Sintel. Screenshots: `runtime-public-links`,
  `runtime-public-link-revoke-failed`, `runtime-public-links-empty`,
  `runtime-public-links-loading`, `runtime-public-links-failed`. Boards:
  `rd-ios-acc-11-links-empty`, `rd-ios-acc-12-links`,
  `rd-ios-acc-35-links-menu`, `rd-ios-acc-36-links-swipe`,
  `rd-ios-acc-37-links-revoke`, `rd-ios-acc-38-links-loading`,
  `rd-ios-acc-39-links-failed`.
- **iPad list and detail.** Boards: `rd-ios-acc-57-ipad-account`,
  `rd-ios-acc-18-ipad-privacy`, `rd-ios-acc-20-ipad-proxy`,
  `rd-ios-acc-58-ipad-danger`.

## Gotchas

- Account rows load lazily. Scroll until the row exists before you tap it.
- Sign-out asks once: an alert (`confirm-alert.confirm`) with no downloads,
  otherwise a dialog with `auth.sign-out-confirm` and
  `auth.sign-out-remove-downloads`.
- Session rules live in [session lifecycle](../../../../docs/session.md).
