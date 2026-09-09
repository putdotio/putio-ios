# iOS deep links

The iOS shell opens the existing Files, History, and Account surfaces from
these paths:

| Path | Destination |
| --- | --- |
| `/files/0` | Files root |
| `/files/<positive integer>` | Folder or video, resolved through the SDK |
| `/history` | History, when enabled in account settings |
| `/account`, `/settings` | Account root |

Custom-scheme URLs retain the legacy path convention: `putio:///files/410`
and `putio://put.io/files/410` use `/files/410` as the path. A host such as
`putio://files/410` is not a route. The dispatcher also accepts HTTPS URLs
on `put.io` and its subdomains when delivered to the app. Universal-link
entitlements and domain association for the new app are separate work.

Credentials, explicit ports, query strings, fragments, encoded path components,
and malformed IDs are not accepted as navigation input. Foreign schemes and
hosts are ignored. Unsupported owned paths, unavailable files, disabled History,
and file types without a viewer show an explanation with Close; recoverable file
lookup failures also offer retry. Preview, downloaded-file, and device-approval
routes remain with their owning features.

Links received before sign-in wait in memory. A link bound to an authenticated
account is discarded when that session ends or the account changes. Only typed
route values are retained, never the incoming URL. Resolving a new link or
cancelling invalidates older lookup results. Folder ancestry is fetched through
the SDK before navigation, and deep links take precedence over saved navigation
restoration.

The files-browser harness journey exercises native cold and warm URL delivery,
signed-out intent replay, restored-session dispatch, conflicting saved-folder
restoration, native Back ancestry, video dismissal, and loading,
error, retry, and unsupported outcomes. Its published artifacts use synthetic
files and URLs.
