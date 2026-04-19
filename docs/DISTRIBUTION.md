# Distribution

Distribution guidance for `putio-ios`.

## Workflows

- `.github/workflows/ci.yml`
  - verify only
  - runs `make bootstrap-ci` and `make verify`
  - skips docs-only pushes and pull requests
- `.github/workflows/beta.yml`
  - manual TestFlight path
  - verifies first
  - loads secrets through `OP_SERVICE_ACCOUNT_PUTIO_FRONTEND_CI`
  - always targets external TestFlight groups
  - splits delivery into archive, upload, and distribute steps
  - uses a bounded App Store Connect processing timeout
- `.github/workflows/release.yml`
  - runs on published GitHub releases
  - builds from the release tag
  - owns the `fastlane release` invocation

## CI Bootstrap

- `make bootstrap-ci`
  - reuses `Pods` when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale

## Fastlane Contract

- `fastlane beta` and `fastlane release` are CI-only entrypoints
- `make beta` and `make release` intentionally fail locally
- shared 1Password loading and secret materialization live in `.github/actions/load-ios-release-secrets/action.yml`
- uploaded beta and release builds use UTC timestamp build numbers in `YYMMDDHHMM` format
- checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
- fastlane temporarily updates tracked version metadata during archive time and restores the files afterward

## Secrets And IDs

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
- privacy usage strings in `Putio/Info.plist` must stay aligned with enabled SDK features
- Blacksmith macOS minutes are normalized aggressively, so prefer local validation and Fastlane contract checks before rerunning full beta uploads
