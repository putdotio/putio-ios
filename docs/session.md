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

## Sign-out recovery

Sign-out removes the saved credential and revokes the server session. If either
fails, the app shows a retry and blocks sign-in and restoration in that instance
until cleanup succeeds. The failed operation is covered by the
[session tests](../Packages/PutioCore/Tests/PutioCoreTests/PutioSessionStoreTests.swift).

Sign-out intent is not persisted. If credential removal and revocation both
fail, reopening the app can restore the retained token. Complete the retry
before closing the app. Changing this behavior requires a persistent recovery
contract, not just a different error message.
