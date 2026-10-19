# Distribution

The native SwiftUI rewrite lives on `next`.
[Next CI](../.github/workflows/ci-next.yml) verifies it without signing or publishing.
The App Store app lives on protected `main`, whose workflows own signing,
versioning, App Store Connect, and the GitHub `release` Environment.

## Releases from main

`main` is the repository's default branch, so GitHub dispatches its own Beta,
Release, Screenshots, and Submit workflows directly. Their input definitions
on `main` are the source of truth; each takes the current protected-main head
as `expected_sha`:

```bash
sha="$(gh api repos/putdotio/putio-ios/branches/main --jq .commit.sha)"
gh workflow run beta.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha"
gh workflow run release.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha" -f version=<x.y.z>
gh workflow run screenshots.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha" -f app_version=<x.y.z> -f dry_run=true
gh workflow run submit.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha" -f version=<x.y.z> -f build_number=<build>
```

Release uploads and attaches the build, then tags the commit `v<version>` as
the `putio-ci` App, with an annotated tag that names the build number; it never
submits. Submit sends that build to App Review only when the tag points at the
validated commit and names the build, and dispatching it is the approval. Release, Submit, and Screenshots for one
version share the `app-store-<version>` concurrency group.

Inspect registration without starting a release:

```bash
gh workflow list --repo putdotio/putio-ios
gh workflow view release.yml --repo putdotio/putio-ios --ref main
```

[App Store release tracking](https://github.com/putdotio/putio-ios/issues/149) owns
the App Store rollout.

## App Store as code

[asc](https://asccli.sh) replaces fastlane for App Store delivery
([migration](https://github.com/putdotio/putio-ios/issues/392)). The shipping
line keeps its listing in the repository and CI applies it, so nothing it
manages is edited in App Store Connect:

| What                                                              | Source                                                                                                           |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Name, description, keywords, URLs, What's New                     | `metadata/` in asc's canonical format; `metadata/version/<version>/en-US.json` carries that version's `whatsNew` |
| Release type, phased release, age-rating answers, screenshot sets | `Config/AppStore.json`                                                                                           |
| Screenshots                                                       | `screenshots/<locale>/`, rendered by the image pipeline                                                          |

A field left out of `metadata/` stays unmanaged: asc never clears it.
[The store tool](../scripts/app-store.ts) reads both and drives asc:

```bash
node scripts/app-store.ts check --version 3.0.0        # offline: metadata, What's New, screenshots
node scripts/app-store.ts plan --version 3.0.0         # read-only diff against App Store Connect
node scripts/app-store.ts apply --version 3.0.0 --confirm
node scripts/app-store.ts validate --version 3.0.0     # asc validate, blockers fail
node scripts/app-store.ts screenshots --version 3.0.0 --dry-run
```

`plan` and `screenshots` stop with the version's state when App Store Connect
won't edit it, such as while it waits for or is in review.

The listing, `Config/AppStore.json`, and the workflows that run the tool live on
the line that ships, protected `main`, whose `release` Environment holds the
App Store Connect key. `next` carries the tool and its tests until the rewrite
ships.

### asc pin and telemetry

[install-asc.sh](../scripts/install-asc.sh) pins asc 5.15.0 and checks each
platform's SHA-256 before installing. CI installs asc only through it, never
from Homebrew. Bump the version and every checksum together.

asc sends command telemetry to rork.com by default. 5.15.0 turns it off when
`ASC_TELEMETRY_DISABLED` or `DO_NOT_TRACK` is set. Every workflow that runs asc
sets `ASC_TELEMETRY_DISABLED=1` before its first asc command, and the store
tool sets it for each call and refuses to run while `asc telemetry status`
reports telemetry on. The `App Store tooling` job in
[Next CI](../.github/workflows/ci-next.yml) proves the pin and the opt-out on a
fresh runner. Locally, run `asc telemetry disable` once after installing.

`asc web` subcommands use an Apple ID web session and private endpoints; they
never run in CI.

### Signing

`main` keeps fastlane `match --readonly` for signing. asc can't read
the match repository: `asc signing sync pull` only reads its own `*.enc`
envelopes, and App Store Connect never returns a certificate's private key.
Moving to `asc signing sync` means decrypting the distribution identity from
match locally and pushing it with `asc signing sync push --identity`, without
creating or revoking a certificate. Do that when the rewrite starts signing.

### App Privacy

App Privacy is the one manual step: the App Store Connect API can't write it.
Update it in App Store Connect when the privacy manifest changes. To check for
drift locally, `asc web privacy plan` compares a declaration file with the live
answers through an Apple ID web session.

## Changing branch ownership

The [branch-flip task](https://github.com/putdotio/putio-ios/issues/145) owns
moving the App Store app off `main` and promoting the rewrite. Update the
delivery trust rule, Environment branch policies, and workflow triggers
together. A fixed
`refs/heads/main` rule must not silently follow `main` to a different app line.
