# Distribution

The native SwiftUI rewrite lives on `next`.
[Next CI](../.github/workflows/ci-next.yml) verifies it without signing or publishing.
The shipping legacy iOS app lives on protected `main`, whose workflows own
signing, versioning, App Store Connect, and the GitHub `release` Environment.

## Legacy releases

Use the [Beta](../.github/workflows/beta.yml) or
[Release](../.github/workflows/release.yml) entrypoint. Their input definitions
are the source of truth for release options.

The default branch exposes these entrypoints so GitHub can list them for manual
dispatch. The [dispatcher](../.github/workflows/legacy-ios-dispatch.yml) accepts
only protected `refs/heads/main`, checks the reviewed workflow and ref-guard
blobs, and passes the resolved commit as `expected_sha` to the legacy workflow.
The downstream guard validates that commit before the delivery job loads secrets
and checks out source. The relay itself remains secretless.

A changed workflow blob or moving branch stops dispatch. Review the legacy
workflow change before updating the dispatcher's expected blob IDs; do not bypass
that check or copy signing configuration into the relay. The job summary records
the validated source and downstream run.

Inspect registration without starting a release:

```bash
gh workflow list --repo putdotio/putio-ios
gh workflow view beta.yml --repo putdotio/putio-ios --ref next
gh workflow view release.yml --repo putdotio/putio-ios --ref next
```

[Legacy release tracking](https://github.com/putdotio/putio-ios/issues/149) owns
the App Store rollout.

## Changing branch ownership

The [branch-flip task](https://github.com/putdotio/putio-ios/issues/145) owns
renaming the legacy line and promoting the rewrite. Update the dispatch trust
rule, Environment branch policies, and workflow triggers together. A fixed
`refs/heads/main` rule must not silently follow `main` to a different app line.
