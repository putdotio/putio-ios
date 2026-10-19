# Distribution

## Workflows

- [CI](../.github/workflows/ci.yml) verifies pushes and pull requests. A `changes` job on Linux classifies the diff with [`scripts/ci-affected.sh`](../scripts/ci-affected.sh), then `verify-app` runs `mise run bootstrap-ci` and `mise run verify` on macOS, and `verify-tooling` type-checks the Node scripts and checks the committed marketing images against their inputs, both on Linux. Each lane runs only when the diff can affect it, and an unrecognized path counts as app-affecting — a needless macOS run is cheaper than a missed break. Nothing is filtered at the `on:` level, so both checks always report a state.
- [Beta](../.github/workflows/beta.yml) is the manual TestFlight path for `main`. A secretless job ([Legacy delivery ref contract](../.github/workflows/legacy-delivery-ref.yml)) first requires the exact current protected-main SHA. The Environment-bearing job then checks out that commit, verifies, installs the signing identity with `fastlane signing`, archives with [archive-ios.sh](../scripts/archive-ios.sh), and uploads and distributes with `asc publish testflight --notify`, which emails external testers as pilot did.
- [Release](../.github/workflows/release.yml) is dispatch-only with the same SHA check and a version. It fails before building when `metadata/version/<version>/en-US.json` has no `whatsNew`, uploads with `asc publish appstore` (which creates or finds the version and attaches the build, never submits), then applies the listing and runs `asc validate` into the job summary. A last job tags the commit `v<version>` only after the upload succeeded, as the `putio-ci` GitHub App: it mints a token for this repository with `contents: write` from the `release` Environment's `PUTIO_RELEASE_BOT_APP_ID` and `PUTIO_RELEASE_BOT_PRIVATE_KEY`, because the `v*` ruleset lets only that App and organization admins create tags.
- [Screenshots](../.github/workflows/screenshots.yml) changes the product page without a build: it plans the listing, uploads App Store Connect's current metadata and age rating as an artifact, and previews the screenshot replacement. With `dry_run` off it applies metadata and settings and replaces each screenshot set. It requires the current protected-main SHA, defaults to a dry run, and runs on Linux with only the App Store Connect key.
- [Submit for review](../.github/workflows/submit.yml) takes a version and the build number Release uploaded. It refuses to start unless the `app-store-review` Environment exists with a required reviewer, waits for that approval, then checks the committed What's New offline, attaches the requested build, runs `asc validate --strict` against it, and runs `asc review submit`.
- [E2E Simulator](../.github/workflows/e2e-simulator.yml) runs the mocked XCUITests on macOS against `main` every Monday at 06:00 UTC and on dispatch. It loads no secrets.
- `main` is the repository's default branch, so these workflows are dispatched directly on it. Pass the current protected-main head as `expected_sha`:

  ```bash
  sha="$(gh api repos/putdotio/putio-ios/branches/main --jq .commit.sha)"
  gh workflow run beta.yml --ref main -f expected_sha="$sha"
  gh workflow run release.yml --ref main -f expected_sha="$sha" -f version=<x.y.z>
  gh workflow run screenshots.yml --ref main -f expected_sha="$sha" -f app_version=<x.y.z> -f dry_run=true
  gh workflow run submit.yml --ref main -f expected_sha="$sha" -f version=<x.y.z> -f build_number=<build>
  ```

- Beta, release, and shared release-secret third-party actions are pinned to full commit SHAs with a trailing comment for the human version tag. Update the SHA and comment together after reviewing upstream release notes.

## CI Bootstrap

- `mise run bootstrap-ci`
  - reuses an existing local `Pods` sandbox only when `Pods/Manifest.lock` matches `Podfile.lock`
  - falls back to `pod install` when the cache is stale
- GitHub Actions caches CocoaPods download artifacts only; signed beta/release jobs do not restore a generated `Pods` tree from Actions cache
- Signed beta/release jobs install Ruby gems fresh with Bundler caching disabled before loading App Store Connect and signing secrets

## Delivery Contract

- Beta, release, screenshots, and submit are CI-only; `mise run beta` and `mise run release` intentionally fail locally
- Release secret validation and key-file materialization live in [Load iOS release secrets](../.github/actions/load-ios-release-secrets/action.yml); asc reads the key from `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY` with `ASC_BYPASS_KEYCHAIN=1`
- uploaded beta and release builds use UTC timestamp build numbers in `YYMMDDHHMM` format, passed to `xcodebuild` as `CURRENT_PROJECT_VERSION`; release passes its version as `MARKETING_VERSION`, so no tracked file changes at archive time
- checked-in `CURRENT_PROJECT_VERSION` stays at `1` as a baseline
- Manual dispatches require `expected_sha` to equal both the workflow event SHA and the current protected `main` head. The validation job is secretless; only its immutable SHA output reaches the `release` Environment job.
- App icons follow the put.io design-system flavors: `AppIconDev` locally, `AppIconNightly` on TestFlight, `AppIcon` on the App Store

## App Store as code

Nothing the repository manages is edited in App Store Connect:

| What | Source |
| --- | --- |
| Name, description, keywords, URLs, What's New | `metadata/` in asc's canonical format; `metadata/version/<version>/en-US.json` carries that version's `whatsNew` |
| Release type, phased release, age-rating answers, screenshot sets | [`Config/AppStore.json`](../Config/AppStore.json) |
| Screenshots | `screenshots/<locale>/`, written by `mise run store-images`; locale folders must be App Store locales such as `en-US` |

A field left out of `metadata/` stays unmanaged: asc never clears it. To adopt
one, take it from the Screenshots dry run's artifact and commit it.
[The store tool](../scripts/app-store.ts) drives asc:

```bash
node scripts/app-store.ts check --version 3.0.0        # offline: metadata, What's New, screenshots
node scripts/app-store.ts plan --version 3.0.0         # read-only diff against App Store Connect
node scripts/app-store.ts apply --version 3.0.0 --confirm
node scripts/app-store.ts validate --version 3.0.0     # asc validate, blockers fail
node scripts/app-store.ts screenshots --version 3.0.0 --dry-run
```

[install-asc.sh](../scripts/install-asc.sh) pins asc 5.15.0 and checks each
platform's SHA-256; CI never installs asc from Homebrew. Delivery steps run `shell: bash`, so an asc failure piped into the job summary still fails the step. asc sends command
telemetry to rork.com by default, so every workflow that runs it sets
`ASC_TELEMETRY_DISABLED=1` before its first asc command, the store tool
refuses to run while `asc telemetry status` reports it on, and the tooling CI
lane proves both. Locally, run `asc telemetry disable` once after installing.
`asc web` subcommands use an Apple ID web session and never run in CI.

### Signing

`fastlane signing` is the only fastlane lane left: it runs `match --readonly`
into a fresh keychain. asc can't read the match repository, because `asc
signing sync pull` only reads its own `*.enc` envelopes and App Store Connect
never returns a certificate's private key. Moving means decrypting the
distribution identity from match locally and pushing it with `asc signing sync
push --identity`, without creating or revoking a certificate.

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
- Release tagging, used only by the Release workflow's `tag` job:
  - `PUTIO_RELEASE_BOT_APP_ID` (variable): the `putio-ci` App, `3648620`
  - `PUTIO_RELEASE_BOT_PRIVATE_KEY`
- Brand fonts need no credentials: the "Sync licensed brand fonts" step
  downloads them from `static.put.io` and verifies each sha256 from
  `Config/BrandFonts.json`, failing the workflow on a bad download or a
  mismatch, so a system-font build cannot ship silently

Keep item IDs, service-account tokens, and private key material out of git.

Product analytics needs no Environment field: `Config/Release.xcconfig` carries PostHog's public project token, which only names the project, so Debug, verify, and e2e builds have none. The app sends through `burrow.put.io` only from the `com.putio.tvOS` bundle and only while a signed-in account's `product_analytics_enabled` is on; TestFlight installs tag their events `release_channel: beta`.

## TestFlight Diagnostics Check

One controlled, non-fatal event proves a build's Sentry path. Run the check on the beta, then again on the release-lane upload before submitting it for review. `release` archives its own binary and never submits it, so add that build to an internal TestFlight group and install it from TestFlight.

1. On a TestFlight device, sign in to an account whose `diagnostics_enabled` is on.
2. Open `putio://diagnostics-check` from Safari or Notes. Nothing changes on screen. The install's receipt decides, not the lane: a TestFlight install sends the event, and an App Store install ignores the link. With diagnostics off the event is dropped like any other.
3. In Sentry project `ios` (`5282170`), not `tvos`, find `category:diagnostics_check` and confirm release `com.putio.tvOS@3.0.0+<build>` for the installed build, environment `production`, OS `iOS` or `iPadOS`, and `app.build_type` `test`. TestFlight and App Store events share the `production` environment, so the build type is what tells them apart.

Never paste the DSN or the event payload into issues, pull requests, or logs.

## App Privacy

The App Privacy answers in App Store Connect must match Organizer's privacy report, which merges [`Putio/PrivacyInfo.xcprivacy`](../Putio/PrivacyInfo.xcprivacy) with the SDKs' own manifests. The answers, their sources, and the open questions live in [iOS legacy release](https://app.notion.com/p/3fdd546ba2f581a29718c0deeac09e20) in the put.io Notion; change the manifest and that page together.

App Privacy is the one manual step: the App Store Connect API can't write it. To check for drift locally, `asc web privacy plan --app 1260479699 --file <declaration.json>` compares a declaration with the live answers through an Apple ID web session.

Organizer's Generate Privacy Report has no command-line equivalent. CI deletes its archives, so archive locally, then open the archive in Organizer:

```sh
xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/privacy/Putio.xcarchive CODE_SIGNING_ALLOWED=NO archive
open build/privacy/Putio.xcarchive
```

## GitHub Release Settings

Repository admins must keep these settings aligned with the workflow trust model:

- protect `main` for trusted team direct push; do not allow force-pushes or branch deletion
- protect `v*` release tags so only release automation or release admins can create or update them; `putio-ci` holds the bypass the Release workflow tags with
- configure the `release` Environment with required reviewers and prevent self-review

## App Store IDs

- App Store Connect app ID `1260479699`, in `Config/AppStore.json` and the asc commands
- `PUTIO_APPLE_ID`: Apple login email used by `match`
- `putdotio/putio-code-signing-apple` is pinned to the `main` branch in `fastlane/Matchfile`

## Operational Notes

- App Store Connect upload success does not mean external distribution is complete
- Apple processing failures may surface only after upload
- release uploads must complete App Store Connect processing before promotion or submission can continue
- privacy usage strings in `Putio/Info.plist` must stay aligned with enabled SDK features
- Beta and release run on GitHub-hosted macOS runners, whose minutes count tenfold against the organization's included minutes, so prefer local validation and `node scripts/app-store.ts check` before rerunning full beta uploads
