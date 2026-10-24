# Account

A signed-in user manages security, file and privacy preferences, and history,
reaches rating and support links, answers the analytics prompt, and recovers
from a sign-out that did not finish.

## Sub-features

- `sign-out-recovery` keeps the user out of a new sign-in until a failed
  sign-out is retried.
- `security` shows recovery codes, links a device by code, lists apps, clears
  data, and destroys the account.
- `file-preferences` recovers a failed save, resets, keeps settings across
  relaunch, and hides History when it is off.
- `history` pages, opens items, deletes, and follows the History setting.
- `rating` opens rating and contact links only after an explicit tap.
- `analytics-prompt` retries a failed save and saves the choice once.

## How to get to it (user POV)

- Account tab; lower rows such as Sign out need a scroll.
- History tab, shown while History is on.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures. `sign-out-recovery` starts signed in with a
  forced sign-out failure.

- **Sign-out recovery.** Run `--only sign-out-recovery`. "Sign-out did not
  finish" shows with a retry and no sign-in. Screenshot:
  `runtime-sign-out-failure`.
- **Security.** Run `--only account-security`. Screenshots:
  `runtime-security-recovery-codes`, `runtime-security-apps`,
  `runtime-danger-clear-data`.
- **File preferences.** Run `--only file-preferences`. Screenshots:
  `runtime-file-preferences`, `runtime-file-preferences-refresh`,
  `runtime-privacy-controls`.
- **History.** Run `--only history`. Screenshots: `runtime-history-loaded`,
  `runtime-history-error`, `runtime-history-empty`.
- **Rating.** Run `--only account-rating`. Screenshot: `runtime-account-rating`.
- **Analytics prompt.** Run `--only analytics-prompt`. Screenshot:
  `runtime-analytics-prompt`.

## Gotchas

- Account rows load lazily. Scroll until the row exists before you tap it.
- Sign-out asks "Are you sure?" first (`auth.sign-out-confirm`).
- Session rules live in [session lifecycle](../../../../docs/session.md).
