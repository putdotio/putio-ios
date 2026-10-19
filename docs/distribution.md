# Distribution

The native SwiftUI rewrite lives on `next`.
[Next CI](../.github/workflows/ci-next.yml) verifies it without signing or publishing.
The shipping legacy iOS app lives on protected `main`, whose workflows own
signing, versioning, App Store Connect, and the GitHub `release` Environment.

## Legacy releases

`main` is the repository's default branch, so GitHub dispatches its own Beta,
Release, and Screenshots workflows directly. Their input definitions on `main`
are the source of truth; each takes the current protected-main head as
`expected_sha`:

```bash
sha="$(gh api repos/putdotio/putio-ios/branches/main --jq .commit.sha)"
gh workflow run beta.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha"
gh workflow run release.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha" -f version=<x.y.z>
gh workflow run screenshots.yml --repo putdotio/putio-ios --ref main -f expected_sha="$sha" -f app_version=<x.y.z> -f dry_run=true
```

The [Beta](../.github/workflows/beta.yml),
[Release](../.github/workflows/release.yml), and
[Screenshots](../.github/workflows/screenshots.yml) relays on `next` and their
[dispatcher](../.github/workflows/legacy-ios-dispatch.yml) date from when `next`
was the default branch. They are superseded: dispatching a file name without
`--ref` now runs `main`'s workflow, and the relays run only if someone passes
`--ref next`. Don't use them for delivery.

Inspect registration without starting a release:

```bash
gh workflow list --repo putdotio/putio-ios
gh workflow view release.yml --repo putdotio/putio-ios --ref main
```

[Legacy release tracking](https://github.com/putdotio/putio-ios/issues/149) owns
the App Store rollout.

## Changing branch ownership

The [branch-flip task](https://github.com/putdotio/putio-ios/issues/145) owns
renaming the legacy line and promoting the rewrite. Update the dispatch trust
rule, Environment branch policies, and workflow triggers together. A fixed
`refs/heads/main` rule must not silently follow `main` to a different app line.
