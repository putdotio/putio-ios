# Distribution

The repository temporarily carries two distinct application lines:

- `next` is the default branch and owns the new iOS, watchOS, and tvOS apps. [Next CI](../.github/workflows/ci-next.yml) verifies that workspace; it does not sign or publish an app.
- protected `main` owns the shipping legacy iOS 3.x app. Its existing beta and release workflows remain the only owners of Fastlane, signing, Match, versioning, App Store Connect, and the GitHub `release` Environment contract.

## Legacy delivery entrypoints

GitHub registers manual workflows from the default branch, so the legacy workflows on `main` disappeared from the normal Actions dispatch surface when `next` became default. The default branch now exposes two explicitly legacy entrypoints at the same paths as the established `main` workflows:

- [Legacy iOS 3.x Beta](../.github/workflows/beta.yml)
- [Legacy iOS 3.x Release](../.github/workflows/release.yml)

Both entrypoints run a secretless [legacy dispatch contract](../.github/workflows/legacy-ios-dispatch.yml). It accepts only `refs/heads/main`, verifies through the GitHub API that `main` is protected, resolves and records its current commit SHA, and checks that the selected workflow's Git blob still matches the reviewed legacy contract. It then dispatches the same workflow path on `main`.

The downstream run therefore uses the workflow and source from protected `main`. GitHub evaluates its `release` Environment branch policy against `main`, and only that downstream run can load the existing Environment secrets and signing material. The default-branch entrypoint never checks out or executes legacy app code, loads release secrets, signs an artifact, or uploads a build.

The workflow-blob check fails closed if the legacy beta or release orchestration changes on `main`. Review that change against the release contract before updating the corresponding blob ID in the dispatcher; do not bypass the check or copy signing policy into the relay.

### Inputs and output identity

- Both entrypoints expose a `legacy_ref` choice with the sole trusted value `refs/heads/main`. API callers receive the same server-side validation as UI callers.
- Beta forwards only the established `changelog`, `groups`, and `processing_timeout_minutes` inputs to `main`.
- Release requires a three-component legacy App Store version such as `3.1.0` and forwards it to `main`.
- Workflow names, run names, input descriptions, and the relay job summary identify the line as legacy iOS 3.x and record the protected-main SHA, reviewed workflow blob, and downstream delivery-run link.

After this change merges to the default branch, verify registration without dispatching delivery:

```bash
gh workflow list --repo putdotio/putio-ios
gh workflow view beta.yml --repo putdotio/putio-ios --ref next
gh workflow view release.yml --repo putdotio/putio-ios --ref next
```

A maintainer-approved beta dispatch is separate acceptance for [#162](https://github.com/putdotio/putio-ios/issues/162) before [#149](https://github.com/putdotio/putio-ios/issues/149) performs the App Store release.

## Branch-flip cleanup

[#145](https://github.com/putdotio/putio-ios/issues/145) owns the eventual branch flip. After the legacy app ships, that work renames the current `main` line to protected `legacy`, makes the new app line `main`, updates Environment branch policies and workflow triggers deliberately, and removes or rewires these temporary relay entrypoints. Do not leave the fixed `refs/heads/main` trust rule in place after `main` changes ownership.
