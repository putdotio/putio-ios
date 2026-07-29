# Distribution

Distribution guidance for `putio-ios`.

## Workflows

- [CI](../.github/workflows/ci.yml) verifies pushes and pull requests. A `changes` job on Linux classifies the diff with [`scripts/ci-affected.sh`](../scripts/ci-affected.sh), then `verify-app` runs `mise run bootstrap-ci` and `mise run verify` on macOS, and `verify-tooling` type-checks the Node scripts on Linux. Each lane runs only when the diff can affect it, and an unrecognized path counts as app-affecting — a needless macOS run is cheaper than a missed break. Nothing is filtered at the `on:` level, so both checks always report a state.
- [Beta](../.github/workflows/beta.yml) is the manual TestFlight path for `main`. It verifies first, prepares metadata, loads release secrets, then splits delivery into archive, upload, and distribute steps.
- [Release](../.github/workflows/release.yml) runs on published GitHub releases and builds the release artifact from the release tag. Manual dispatch builds from `main` for the supplied version.
- [Screenshots](../.github/workflows/screenshots.yml) is a dispatch-only lane that uploads the committed App Store images from `fastlane/screenshots/` and nothing else. It defaults to a dry run. It builds no app: no Xcode, no CocoaPods, no simulator.
  - The release lane keeps `skip_screenshots: true` on purpose. Shipping a build and changing the product page are separate decisions, and coupling them means every release either silently republishes the listing or silently does not.
  - `overwrite_screenshots: true` is required: App Store Connect appends otherwise, which would leave the 2024 images beside the new ones.
- Beta, release, and shared release-secret third-party actions are pinned to full commit SHAs with a trailing comment for the human version tag. Update the SHA and comment together after reviewing upstream release notes.

## CI Bootstrap

- `mise run bootstrap-ci`
  - reuses an existing local `Pods` sandbox only when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale
- GitHub Actions caches CocoaPods download artifacts only; signed beta/release jobs do not restore a generated `Pods` tree from Actions cache
- Signed beta/release jobs install Ruby gems fresh with Bundler caching disabled before loading App Store Connect and signing secrets

## Fastlane Contract

- `fastlane beta` and `fastlane release` are CI-only entrypoints
- `mise run beta` and `mise run release` intentionally fail locally
- Release secret validation and key-file materialization live in [Load iOS release secrets](../.github/actions/load-ios-release-secrets/action.yml)
- uploaded beta builds use UTC timestamp build numbers in `YYMMDDHHMM` format
- release builds use UTC timestamp build numbers in `YYMMDDHHMM` format and upload the IPA produced from the checked-out source
- checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
- fastlane temporarily updates tracked version metadata during archive time and restores the files afterward

## Release Secret Contract

Beta and release workflows read GitHub `release` Environment secrets directly.
The canonical source copy for those values stays in the 1Password CI/restricted
vault for human administration and rotation, but CI must not call 1Password or
use `OP_SERVICE_ACCOUNT_TOKEN` at runtime.

The `release` Environment must provide:

- App Store Connect API fields:
  - `APPSTORE_CONNECT_ISSUER_ID`
  - `APPSTORE_CONNECT_KEY_ID`
  - `APPSTORE_CONNECT_KEY_CONTENT`
- App metadata and runtime fields:
  - `PUTIO_APP_IDENTIFIER`
  - `PUTIO_APPLE_ID`
  - `PUTIO_ITC_TEAM_ID`
  - `PUTIO_DEVELOPMENT_TEAM`
  - `PUTIO_OAUTH_CLIENT_ID`
  - `PUTIO_CHROMECAST_RECEIVER_APP_ID`
- Optional support and telemetry fields:
  - `PUTIO_INTERCOM_API_KEY`
  - `PUTIO_INTERCOM_APP_ID`
  - `PUTIO_SENTRY_DSN`
- Signing fields:
  - `MATCH_GIT_URL`
  - `MATCH_TYPE`
  - `MATCH_PASSWORD`
  - `MATCH_GIT_PRIVATE_KEY_CONTENT`
  - `MATCH_GIT_URL` must use a `github.com` SSH URL; CI verifies GitHub's ed25519 host-key fingerprint before updating `known_hosts`
- Brand fonts need no credentials: the "Sync licensed brand fonts" step
  downloads them from `static.put.io` and verifies each sha256 from
  `Config/BrandFonts.json`, failing the workflow on a bad download or a
  mismatch, so a system-font build cannot ship silently

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
- `putdotio/putio-code-signing-apple` is pinned to the `main` branch in `fastlane/Matchfile`

## Operational Notes

- App Store Connect upload success does not mean external distribution is complete
- Apple processing failures may surface only after upload
- release uploads must complete App Store Connect processing before promotion or submission can continue
- privacy usage strings in `Putio/Info.plist` must stay aligned with enabled SDK features
- Blacksmith macOS minutes are normalized aggressively, so prefer local validation and Fastlane contract checks before rerunning full beta uploads
