# iOS deep links

Use `putio:///files/410` to open an item by ID, or `putio:///files/0` for Files
root. The [parser](../Apps/iOS/Sources/DeepLinks.swift) (`PutioDeepLink.parse`)
also routes `/history` to History when enabled and `/account` or `/settings` to
Account. Non-folder files use the [normal file dispatcher](../Apps/iOS/Sources/PutioApp.swift)
(`selectFile`): video, audio, preview, or an unsupported-file explanation.

## URL delivery

Custom-scheme URLs retain the legacy path convention: `putio:///files/410`
and `putio://put.io/files/410` use `/files/410` as the path.
`putio://files/410` is ignored because its host is not a route. The parser also
accepts HTTPS URLs on `put.io` and its subdomains when delivered to the app;
this does not register universal-link delivery. Only Putio registers the
canonical scheme in [Project.swift](../Project.swift), so Nightly does not
compete for it when both flavors are installed.

Foreign schemes and hosts are ignored. Credentials, explicit ports, query
strings, fragments, encoded path components, malformed IDs, and unsupported
owned paths produce an unavailable-link explanation. File lookup failures offer
retry where `PutioDeepLinkFailure.canRetry` allows it. Authentication callbacks
remain with `ASWebAuthenticationSession`.

## Session and navigation

Links received before sign-in wait in memory. Once bound to an authenticated
account, a link is discarded when sign-out begins or the account changes.
Only typed routes are retained, never incoming URLs. A new link or cancellation
invalidates older lookup results.

`PutioDeepLinkModel.resolveFile` fetches folder ancestry before navigation.
The destination replaces the Files path and takes precedence over saved folder
restoration, so native Back follows the linked item's parents.

[DeepLinkTests](../Tests/iOS/Sources/DeepLinkTests.swift) cover parsing, session
binding, cancellation, and resolution. The
[deep-link journey](../Tests/iOSUITests/Sources/DeepLinkJourneyTests.swift) covers
native cold/warm delivery and navigation with synthetic URLs and files. Run it
as part of the [Files journey](harness.md#choose-the-proof):

```bash
mise run harness -- journey --platform ios --scenario files-browser
```
