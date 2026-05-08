# Distribution

Distribution guidance for `putio-ios`.

## Workflows

- [CI](../.github/workflows/ci.yml) verifies pushes and pull requests with `make bootstrap-ci` and `make verify`. It skips docs-only changes.
- [Beta](../.github/workflows/beta.yml) is the manual TestFlight path for `main`. It verifies first, prepares metadata, loads release secrets, then splits delivery into archive, upload, and distribute steps.
- [Release](../.github/workflows/release.yml) runs on published GitHub releases and builds the release artifact from the release tag. Manual dispatch builds from `main` for the supplied version.
- Beta, release, and shared release-secret third-party actions are pinned to full commit SHAs with a trailing comment for the human version tag. Update the SHA and comment together after reviewing upstream release notes.

## CI Bootstrap

- `make bootstrap-ci`
  - reuses an existing local `Pods` sandbox only when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale
- GitHub Actions caches CocoaPods download artifacts only; signed beta/release jobs do not restore a generated `Pods` tree from Actions cache

## Fastlane Contract

- `fastlane beta` and `fastlane release` are CI-only entrypoints
- `make beta` and `make release` intentionally fail locally
- 1Password loading and secret materialization live in [Load iOS release secrets](../.github/actions/load-ios-release-secrets/action.yml)
- uploaded beta builds use UTC timestamp build numbers in `YYMMDDHHMM` format
- release builds use UTC timestamp build numbers in `YYMMDDHHMM` format and upload the IPA produced from the checked-out source
- checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
- fastlane temporarily updates tracked version metadata during archive time and restores the files afterward

## Release Secret Contract

Beta and release workflows authenticate via the `OP_SERVICE_ACCOUNT_TOKEN` Environment-scoped secret. The release-secret action reads from the hardcoded `frontend-ci/putio-ios` 1Password item.

The 1Password item must provide:

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

Keep item IDs, service-account tokens, and private key material out of git.

## GitHub Release Settings

Repository admins must keep these settings aligned with the workflow trust model:

- protect `main` for trusted team direct push; do not allow force-pushes or branch deletion
- protect `v*` release tags so only release automation or release admins can create or update them
- configure the `release` Environment with required reviewers and prevent self-review

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
- release uploads must complete App Store Connect processing before promotion or submission can continue
- privacy usage strings in `Putio/Info.plist` must stay aligned with enabled SDK features
- Blacksmith macOS minutes are normalized aggressively, so prefer local validation and Fastlane contract checks before rerunning full beta uploads
