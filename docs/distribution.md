# Distribution

What the workflows, the store tool, and the `release` Environment rely on.
The release runbook, the TestFlight diagnostics check, App Privacy answers,
secret rotation, and GitHub settings live in
[iOS release](https://app.notion.com/p/3fdd546ba2f581a29718c0deeac09e20)
in the put.io Notion.

## Workflows

| Workflow                                                | Does                                                                                                                              |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| [CI](../.github/workflows/ci.yml)                       | Verifies pushes and pull requests; [ci-affected.sh](../scripts/ci-affected.sh) skips lanes the diff can't affect                  |
| [Beta](../.github/workflows/beta.yml)                   | Archives, uploads to TestFlight, and emails external testers                                                                      |
| [Release](../.github/workflows/release.yml)             | Archives and uploads, applies the listing, runs `asc validate`, and tags `v<version>` with `Build-Number: <build>`; never submits |
| [Screenshots](../.github/workflows/screenshots.yml)     | Plans the listing and previews screenshots; with `dry_run` off, applies the listing and replaces the screenshot sets              |
| [Submit](../.github/workflows/submit.yml)               | Attaches Release's build to the tagged version, runs `asc validate --strict`, and submits it to App Review                        |
| [Signing Check](../.github/workflows/signing-check.yml) | Proves the signing secrets without building; creates, renews, and revokes nothing                                                 |
| [E2E Simulator](../.github/workflows/e2e-simulator.yml) | Runs the mocked XCUITests against `main` every Monday and on dispatch                                                             |

Dispatch them on `main`, passing its current head as `expected_sha`; Submit
takes none:

```bash
sha="$(gh api repos/putdotio/putio-ios/branches/main --jq .commit.sha)"
gh workflow run beta.yml --ref main -f expected_sha="$sha"
gh workflow run release.yml --ref main -f expected_sha="$sha" -f version=<x.y.z>
gh workflow run screenshots.yml --ref main -f expected_sha="$sha" -f app_version=<x.y.z> -f dry_run=true
gh workflow run submit.yml --ref main -f version=<x.y.z> -f build_number=<build>
gh workflow run signing-check.yml --ref main -f expected_sha="$sha"
```

## Delivery contract

- Beta, Release, Screenshots, Submit, and Signing Check run only in CI. A
  secretless job ([Delivery ref contract](../.github/workflows/delivery-ref.yml))
  requires `expected_sha` to equal both the event SHA and the protected `main`
  head; only its SHA output reaches the `release` Environment job.
- Submit instead requires `v<version>` to be Release's annotated tag, with the
  requested `Build-Number`, on or behind protected `main`, so a TestFlight build
  with the same version string can't be submitted.
- Release tags as the `putio-ci` GitHub App, from `PUTIO_CI_APP_CLIENT_ID` and
  `PUTIO_CI_APP_PRIVATE_KEY`, because the `v*` ruleset lets only that App and
  organization admins create tags.
- Beta's What to Test notes always come from
  [beta-notes](https://github.com/putdotio/.github#actionsbeta-notes), run
  after `verify`: Claude writes one bullet per user-facing change since the
  latest `v*` tag, and a range with none, or any Claude failure, gives "Bug
  fixes and improvements." The job authenticates through Anthropic workload identity
  federation, so it needs `id-token: write` and a full-history checkout.
- Build numbers are UTC timestamps (`YYMMDDHHMM`) passed as
  `CURRENT_PROJECT_VERSION`; Release passes its version as `MARKETING_VERSION`.
  The checked-in `CURRENT_PROJECT_VERSION` stays `1`, so archiving changes no
  tracked file.
- Signed jobs install Ruby gems fresh with Bundler caching off and never restore
  a generated `Pods` tree from cache; Actions caches only CocoaPods downloads.
- Third-party actions in delivery workflows are pinned to full commit SHAs with
  a trailing version comment; update both together.
- App icons: `AppIconDev` locally, `AppIconNightly` on TestFlight, `AppIcon` on
  the App Store.

## App Store as code

Nothing the repository manages is edited in App Store Connect:

| What                                                              | Source                                                                                                                                                                                                          |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name, description, keywords, URLs                                 | `metadata/` in asc's canonical format; each version needs `metadata/version/<version>/en-US.json`                                                                                                               |
| What's New                                                        | Written by Claude at Release from the changes since the previous version's latest `v*` tag; never committed                                                                                                     |
| Release type, phased release, age-rating answers, screenshot sets | [`Config/AppStore.json`](../Config/AppStore.json)                                                                                                                                                               |
| Screenshots                                                       | `screenshots/<locale>/`, written by `mise run store-images`; locale folders must be App Store locales such as `en-US`                                                                                           |
| App Review sign-in                                                | The `release` Environment's `APP_REVIEW_DEMO_ACCOUNT_*` secrets; `apply` sets them on every version. The review contact stays in App Store Connect, and a version with none fails `apply` until it is set there |

A field left out of `metadata/` stays unmanaged: asc never clears it. To adopt
one, take it from the Screenshots dry run's artifact and commit it.

Release fails before building when the version's listing is missing or commits
a `whatsNew`. After the upload, a secretless job runs
[beta-notes](https://github.com/putdotio/.github#actionsbeta-notes) from the
previous version's latest `v*` tag; the listing job writes its notes, or "Bug
fixes and improvements." when there is no earlier tag or Claude fails, into
the listing in its checkout before `apply`. Submit and Screenshots leave What's
New as Release set it. [The store tool](../scripts/app-store.ts) drives asc:

```bash
node scripts/app-store.ts check --version 3.0.0        # offline: metadata, version listing, screenshots
node scripts/app-store.ts plan --version 3.0.0         # read-only diff against App Store Connect
node scripts/app-store.ts apply --version 3.0.0 --confirm
node scripts/app-store.ts validate --version 3.0.0     # asc validate, blockers fail
node scripts/app-store.ts screenshots --version 3.0.0 --dry-run
```

[install-asc.sh](../scripts/install-asc.sh) pins asc 5.15.0 and checks each
platform's SHA-256; CI never installs asc from Homebrew. Delivery steps run
`shell: bash`, so an asc failure piped into the job summary still fails the
step. asc sends command telemetry to rork.com by default, so every workflow that
runs it sets `ASC_TELEMETRY_DISABLED=1` before its first asc command, the store
tool refuses to run while `asc telemetry status` reports it on, and the tooling
CI lane proves both. Locally, run `asc telemetry disable` once after installing.
`asc web` subcommands use an Apple ID web session and never run in CI.

Beta and Release sign with asc: [install-signing.sh](../scripts/install-signing.sh)
installs `APPLE_DISTRIBUTION_P12` into a temporary keychain,
[check-signing-profile.rb](../scripts/check-signing-profile.rb) picks an active
App Store profile for this team and `PUTIO_APP_IDENTIFIER` that includes the
identity's certificate, and [archive-ios.sh](../scripts/archive-ios.sh) signs
with that profile's UUID. Ruby and Bundler remain only for CocoaPods and the
profile check.

## Release secret contract

Beta, Release, Screenshots, Submit, and Signing Check read GitHub `release`
Environment secrets directly; CI never calls 1Password or uses
`OP_SERVICE_ACCOUNT_TOKEN`. [Load iOS release secrets](../.github/actions/load-ios-release-secrets/action.yml)
validates them for Beta and Release. The `release` Environment must provide:

- App Store Connect API fields: `APPSTORE_CONNECT_ISSUER_ID`,
  `APPSTORE_CONNECT_KEY_ID`, `APPSTORE_CONNECT_KEY_CONTENT`. asc reads them as
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY` with
  `ASC_BYPASS_KEYCHAIN=1`
- App metadata and runtime fields: `PUTIO_APP_IDENTIFIER`,
  `PUTIO_DEVELOPMENT_TEAM`, `PUTIO_OAUTH_CLIENT_ID`,
  `PUTIO_CHROMECAST_RECEIVER_APP_ID`, and `PUTIO_SENTRY_DSN`, the DSN for Sentry
  project `ios`; Beta and Release fail without it
- Intercom fields: `PUTIO_INTERCOM_API_KEY` and `PUTIO_INTERCOM_APP_ID`. Beta and
  Release fail without them, because Contact us and destroy-account support open
  Intercom. Each must match `[A-Za-z0-9._:-]+` and must not be `null`
- Signing identity, for Beta, Release, and Signing Check:
  `APPLE_DISTRIBUTION_P12`, the Apple Distribution certificate and private key as
  one base64 line of a password-protected PKCS#12, and
  `APPLE_DISTRIBUTION_P12_PASSWORD`
- App Review sign-in, for the store tool's `apply` in Release and Screenshots,
  which fails before changing anything without them:
  `APP_REVIEW_DEMO_ACCOUNT_NAME` and `APP_REVIEW_DEMO_ACCOUNT_PASSWORD`, at most
  100 characters
- Release tagging, for the Release workflow's `tag` job:
  `PUTIO_CI_APP_CLIENT_ID` (variable) and `PUTIO_CI_APP_PRIVATE_KEY`

Brand fonts need no credentials: the workflows download them from
`static.put.io` and verify each sha256 from `Config/BrandFonts.json`, so a
system-font build can't ship silently. Product analytics needs none either:
`Config/Release.xcconfig` carries PostHog's public project token.

Keep item IDs, service-account tokens, and private key material out of git.

## App Privacy

The App Privacy answers in App Store Connect must match Organizer's privacy
report, which merges [`Putio/PrivacyInfo.xcprivacy`](../Putio/PrivacyInfo.xcprivacy)
with the SDKs' own manifests, and the usage strings in `Putio/Info.plist` must
match the enabled SDK features. Change the manifest and the Notion answers
together.
