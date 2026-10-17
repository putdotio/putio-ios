# Distribution

Distribution guidance for `putio-ios`.

## Workflows

- [CI](../.github/workflows/ci.yml) verifies pushes and pull requests. A `changes` job on Linux classifies the diff with [`scripts/ci-affected.sh`](../scripts/ci-affected.sh), then `verify-app` runs `mise run bootstrap-ci` and `mise run verify` on macOS, and `verify-tooling` type-checks the Node scripts and checks the committed marketing images against their inputs, both on Linux. Each lane runs only when the diff can affect it, and an unrecognized path counts as app-affecting — a needless macOS run is cheaper than a missed break. Nothing is filtered at the `on:` level, so both checks always report a state.
- [Beta](../.github/workflows/beta.yml) is the manual TestFlight path for `main`. A secretless job first requires the exact current protected-main SHA, then the Environment-bearing job checks out that immutable commit, verifies, prepares metadata, loads release secrets, and splits delivery into archive, upload, and distribute steps.
- [Release](../.github/workflows/release.yml) runs on published semantic `v*` GitHub releases and builds the release artifact from the immutable release-event SHA. Manual dispatch requires the exact current protected-main SHA and supplied version.
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
- Manual beta and release dispatches require `expected_sha` to equal both the workflow event SHA and the current protected `main` head. The validation job is secretless; only its immutable SHA output reaches the `release` Environment job.
- App icons follow the put.io design-system flavors: `AppIconDev` locally, `AppIconNightly` on TestFlight, `AppIcon` on the App Store

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
  - `PUTIO_SENTRY_DSN`: the DSN for Sentry project `ios` (`5282170`); beta and release fail without it. The app posts through `relay.put.io` unless the account's `diagnostics_enabled` is off, so also while signed out and before the account answers
- Intercom fields: beta and release fail without them, because Contact us and destroy-account support open Intercom. Each must match `[A-Za-z0-9._:-]+` and must not be `null`:
  - `PUTIO_INTERCOM_API_KEY`
  - `PUTIO_INTERCOM_APP_ID`
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

Product analytics needs no Environment field: `Config/Release.xcconfig` carries PostHog's public project token, which only names the project, so Debug, verify, and e2e builds have none. The app sends through `burrow.put.io` only from the `com.putio.tvOS` bundle and only while a signed-in account's `product_analytics_enabled` is on; TestFlight installs tag their events `release_channel: beta`.

## TestFlight Diagnostics Check

One controlled, non-fatal event proves a build's Sentry path. Run the check on the beta, then again on the release-lane upload before submitting it for review. `release` archives its own binary and uploads it with `submit_for_review: false`, so add that build to an internal TestFlight group and install it from TestFlight.

1. On a TestFlight device, sign in to an account whose `diagnostics_enabled` is on.
2. Open `putio:///diagnostics-check` from Safari or Notes; the three slashes make it a path. Nothing changes on screen. The install's receipt decides, not the lane: a TestFlight install sends the event, and an App Store install ignores the link. With diagnostics off the event is dropped like any other.
3. In Sentry project `ios` (`5282170`), not `tvos`, find `category:diagnostics_check` and confirm release `com.putio.tvOS@3.0.0+<build>` for the installed build, environment `production`, OS `iOS` or `iPadOS`, and `app.build_type` `test`. TestFlight and App Store events share the `production` environment, so the build type is what tells them apart.

Never paste the DSN or the event payload into issues, pull requests, or logs.

## App Privacy

[`Putio/PrivacyInfo.xcprivacy`](../Putio/PrivacyInfo.xcprivacy) declares what put.io's servers keep, what Sentry and Intercom get, and what the SDKs' own manifests leave out, including the required-reason APIs of Google Cast, which links into the app binary. Organizer's privacy report merges it with those manifests, and the App Privacy answers in App Store Connect must match that report. App Store Connect takes one linked answer per data type: yes when any source links it. Nothing is used for tracking.

Before submitting 3.x, change the 2.58.0 answers to these:

| Data type | 2.58.0 | 3.x | Source |
| --- | --- | --- | --- |
| Email Address | Linked: App Functionality | Unchanged | put.io account; Intercom's manifest |
| User ID | Linked: Analytics, App Functionality | Unchanged | put.io account ID and username; Intercom gets the account ID; PostHog, for Analytics |
| Customer Support | Linked: App Functionality | Unchanged | Intercom conversations |
| Product Interaction | Linked: Analytics, App Functionality | Unchanged | put.io playback positions and IFTTT playback events; Intercom; PostHog events; Google Cast, not linked |
| Other Usage Data | Not declared | Linked: Analytics | PostHog: app version, OS version and device class on each event |
| Crash Data | Linked: App Functionality | Unchanged | Sentry |
| Performance Data | Linked: App Functionality | Linked: Analytics, App Functionality | Sentry, Intercom; Google Cast's nutrition label |
| Other Diagnostic Data | Not declared | Linked: Analytics, App Functionality | Sentry, Intercom, Google Cast; SwiftyBeaver's manifest |
| Device ID | Not declared | Linked: Analytics, App Functionality | Intercom's device ID and push token; Sentry's installation ID and `device_app_hash`; Google Cast, not linked |
| Photos or Videos | Not declared | Linked: App Functionality | Intercom attachments |
| Audio Data | Not declared | Linked: App Functionality | Intercom voice notes |
| Other User Content | Not declared | Linked: App Functionality | put.io folder names and renames |
| Coarse Location | Not declared | Linked: Analytics, App Functionality | Intercom, from the IP address; Google Cast's nutrition label, not linked |
| Search History | Not declared | Unchanged, unless question 2 or 3 is yes | Intercom Help Center search; put.io file search |

- PostHog ([#345](https://github.com/putdotio/putio-ios/issues/345)) sends the account ID as its distinct ID, so User ID keeps Analytics, and its Product Interaction and Other Usage Data are linked although its own manifest says not linked.
- Intercom's rows beyond its manifest come from [its App Store guidance](https://www.intercom.com/help/en/articles/4686934-apple-s-app-store-data-privacy-details-and-intercom-s-ios-sdk). Intercom 19.9.0 also records and uploads voice notes, which `NSMicrophoneUsageDescription` covers.
- Google Cast 4.8.3's `NutritionLabel.txt`, in the SDK download ([Google's guidance](https://developers.google.com/cast/docs/ios_sender/app_privacy)), lists Coarse Location, Device ID, Performance Data and Product Interaction for Analytics and App Functionality. Its manifest declares only Device ID, Other Diagnostic Data and Product Interaction. The app turns Cast's analytics logging off, but that doesn't change Google's declaration, so the app's manifest adds Analytics to Coarse Location and Performance Data.
- [Apple counts free-form text fields](https://developer.apple.com/app-store/app-privacy-details/) as Other User Content, which covers folder names and renames. The app uploads no files and adds no transfers.
- Sentry sends unless the account's `diagnostics_enabled` is off, so also while signed out and before the account answers. Its events carry the random installation ID and `device_app_hash`, a hash of the IDFV, in the `app` context. Neither carries the account, but [Apple counts data as linked](https://developer.apple.com/app-store/app-privacy-details/) to a user's identity "via their account, device, or other details", so Sentry's crash, performance and diagnostic data are linked.

Questions to settle before changing the answers:

1. Does put.io send marketing messages through Intercom? If so, add Developer's Advertising or Marketing to Email Address, Device ID and Product Interaction, here and in the manifest.
2. Does put.io's Messenger offer Help Center search? If so, declare Search History, linked, for Analytics and App Functionality, here and in the manifest.
3. Do put.io's server logs keep file-search text? File search sends the query to put.io as a `GET /files/search` request parameter; whether server logs keep it is unverified. If they do, declare Search History, linked, for App Functionality.

Organizer's Generate Privacy Report has no command-line equivalent. CI deletes its archives, so archive locally, then open the archive in Organizer:

```sh
xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/privacy/Putio.xcarchive CODE_SIGNING_ALLOWED=NO archive
open build/privacy/Putio.xcarchive
```

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
