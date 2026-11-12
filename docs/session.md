# Session lifecycle

[PutioSessionStore](../Packages/PutioCore/Sources/PutioCore/Session/PutioSessionStore.swift)
owns authentication state and saved credentials. The shared
[PutioRuntime](../Packages/PutioCore/Sources/PutioCore/Runtime/PutioRuntime.swift)
checks the session generation around authenticated operations so a late response
cannot change a newer session. Keep that check after every suspension before
applying a session-sensitive result.

On iOS, leaving the signed-in session stops Chromecast playback and disconnects
the receiver. This includes sign-out attempts that fail, session expiry, and
account destruction. The session root owns this cleanup so it still runs when
the signed-in shell disappears. A new sign-in gets fresh Cast preferences.

## Saved credential failures

Restore recovery names its cause: `secureStorage` when the keychain cannot read
or remove the credential, `sessionCheck` when put.io cannot confirm the session
for a reason other than rejecting it. A rejection still ends in the expired
state.

If the keychain cannot be read at launch, restore fails with a retry and keeps
the saved token; both web and device-code sign-in are blocked until restore
succeeds or rejects the credential. A network failure during restore keeps the
token the same way. The recovery screens offer "Try again", which re-runs
restore with the saved token and never starts a browser sign-in. Only the user
can abandon the saved credential: the secondary action ("Sign in again", or
"Reset and sign in" for `secureStorage` on iOS) calls
`discardUnrestoredCredential()`, which removes it from the keychain; iOS then
opens sign-in. The abandoned grant is not revoked;
it stays listed under "Where you are logged in" until revoked there. If removal
fails, restore recovery stays with the `secureStorage` cause.

If a new sign-in saves its token but the account then fails to load for a
non-authentication reason, the store enters the same recovery with the
`sessionCheck` cause. A fresh sign-in would overwrite a grant that put.io still
accepts.

If a new sign-in cannot save its token, the store revokes the new grant on a best-effort basis
and fails sign-in. Expiry and account destruction remove the saved token on a
best-effort basis. A copy left behind fails validation on the next restore,
which removes it again.

## Sign-out recovery

Sign-out saves its intent outside the keychain, revokes the server session,
then removes the saved credential. A failed revocation keeps the credential so
a later launch can still revoke it. The intent clears only when both steps
succeed; put.io rejecting the token counts as revoked.

The user lands on the welcome either way, with no failure screen. While the
intent is set, launch skips restore and retries the cleanup instead, so a
sign-out that did not finish never restores the account. An unreadable
credential stays until a later launch can read it.

Sign-in from the welcome stays available. Saving its token replaces the
credential and clears the intent; the replaced grant is not revoked and stays
listed under "Where you are logged in". The
[session tests](../Packages/PutioCore/Tests/PutioCoreTests/Session/PutioSessionStoreTests.swift)
cover each failure.
