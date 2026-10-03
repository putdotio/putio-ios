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

If the keychain cannot be read at launch, restore fails with a retry and keeps
the saved token; both web and device-code sign-in are blocked until restore
succeeds or rejects the credential. A network failure during restore keeps the
token the same way. The iOS and tvOS recovery screens offer "Try again" and
"Sign in again". Only the user can abandon the saved credential: "Sign in again"
calls `discardUnrestoredCredential()`, which removes it from the keychain and
returns to the normal sign-in. The abandoned grant is not revoked; it stays
listed under "Where you are logged in" until revoked there. If removal fails,
restore recovery stays with the removal error.

If a new sign-in cannot save its token, the store revokes the new grant on a best-effort basis
and fails sign-in. Expiry and account destruction remove the saved token on a
best-effort basis. A copy left behind fails validation on the next restore,
which removes it again.

## Sign-out recovery

Sign-out removes the saved credential and revokes the server session. If either
fails, the app shows a retry and blocks sign-in and restoration in that instance
until cleanup succeeds. The failed operation is covered by the
[session tests](../Packages/PutioCore/Tests/PutioCoreTests/Session/PutioSessionStoreTests.swift).

Sign-out intent is not persisted. If credential removal and revocation both
fail, reopening the app can restore the retained token. Complete the retry
before closing the app. Changing this behavior requires a persistent recovery
contract, not just a different error message.
