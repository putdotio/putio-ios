# Distribution

Distribution guidance for `putio-ios`.

## Workflows

- [CI](../.github/workflows/ci.yml) verifies pushes and pull requests with `make bootstrap-ci` and `make verify`. It skips docs-only changes.
- [Beta](../.github/workflows/beta.yml) is the manual TestFlight path. It verifies first, loads release secrets, then splits delivery into archive, upload, and distribute steps.
- [Release](../.github/workflows/release.yml) runs on published GitHub releases and promotes an existing processed TestFlight build for the release tag version. Manual dispatches may pass an explicit build number.

## CI Bootstrap

- `make bootstrap-ci`
  - reuses `Pods` when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale

## Fastlane Contract

- `fastlane beta` and `fastlane release` are CI-only entrypoints
- `make beta` and `make release` intentionally fail locally
- 1Password loading and secret materialization live in [Load iOS release secrets](../.github/actions/load-ios-release-secrets/action.yml)
- uploaded beta builds use UTC timestamp build numbers in `YYMMDDHHMM` format
- release promotion reuses an existing processed TestFlight build instead of rebuilding
- checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
- fastlane temporarily updates tracked version metadata during archive time and restores the files afterward

## Release Secret Contract

Beta and release workflows pass generic selectors to the release-secret action:

- secret `OP_SERVICE_ACCOUNT_TOKEN`
  - 1Password service account token with access to the selected item
- variable `PUTIO_1PASSWORD_VAULT`
  - vault selector for the release item
- variable `PUTIO_1PASSWORD_ITEM`
  - item selector for the release item

The selected 1Password item must provide:

- App Store Connect API fields:
  - `APPSTORE_CONNECT_ISSUER_ID`
  - `APPSTORE_CONNECT_KEY_ID`
  - `AuthKey.p8`
- App metadata and runtime fields:
  - `PUTIO_APP_IDENTIFIER`
  - `PUTIO_APPLE_ID`
  - `PUTIO_ITC_TEAM_ID`
  - `PUTIO_DEVELOPMENT_TEAM`
  - `PUTIO_OAUTH_CLIENT_ID`
  - `PUTIO_CHROMECAST_RECEIVER_APP_ID`
  - `PUTIO_INTERCOM_API_KEY`
  - `PUTIO_INTERCOM_APP_ID`
  - `PUTIO_SENTRY_DSN`
- Signing fields:
  - `MATCH_GIT_URL`
  - `MATCH_TYPE`
  - `MATCH_PASSWORD`
  - `MATCH_GIT_PRIVATE_KEY`

Keep concrete vault names, item names, item IDs, service-account tokens, and private key material out of git.

## App Store IDs

- `PUTIO_APPLE_ID`
  - Apple login email used by `fastlane/Appfile` and `match`
- `pilot apple_id`
  - numeric App Store Connect app Apple ID
  - do not pass `PUTIO_APPLE_ID` here
- `pilot` distribution should prefer:
  - `app_identifier`
  - `app_platform`
  - numeric app Apple ID only when explicitly available
- `putdotio/apple-certificates` is pinned to the `main` branch in `fastlane/Matchfile`

## Operational Notes

- App Store Connect upload success does not mean external distribution is complete
- Apple processing failures may surface only after upload
- release promotion only succeeds when App Store Connect already has a processed build for the target version
- privacy usage strings in `Putio/Info.plist` must stay aligned with enabled SDK features
- Blacksmith macOS minutes are normalized aggressively, so prefer local validation and Fastlane contract checks before rerunning full beta uploads
