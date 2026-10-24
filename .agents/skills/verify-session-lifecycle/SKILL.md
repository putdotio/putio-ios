---
name: verify-session-lifecycle
description: Model-check put.io sign-in, restore, sign-out, and expiry in PutioSessionStore with TLA+. Use when a change touches PutioSessionStore, the session-generation checks, keychain token handling, revocation, or the screens that call sign-in, restore, or sign-out.
---

# Verify the session lifecycle

[PutioSession.tla](../../../Tests/Formal/Session/PutioSession.tla) models
`PutioSessionStore` as the shipped iOS and tvOS screens drive it. TLC checks
every order of user actions, server answers, put.io revocations, and app
relaunches within the bounds below.

## Properties

- **`NoOrphanGrant`:** every grant put.io still accepts stays in the app: in
  the keychain, in `pendingSignOutToken`, in a pending request, or as the
  signed-in token. Harm: a live session the app can no longer revoke stays
  under "Where you're signed in".
- **`SignedInIsSaved`:** while signed in, the SDK token is the saved token.
  Harm: a relaunch restores a different session, or none.

`NoOrphanGrant` allows the drops that [session lifecycle](../../../docs/session.md)
makes on purpose: the user discards an unrestorable credential, a best-effort
revocation of an unsaved grant fails, or the app quits with a sign-out
revocation pending.

## Run

```bash
mise run formal-session
```

The task downloads TLC 1.7.4 into `build/formal/`, checks its SHA-256, and runs
each property in about 5 seconds. It exits nonzero on a violation, on drift, or
when a model action never fires. An action that never fires means the model
skips the code it names, so fix the action before you trust a pass.

Both properties must hold. Report any other result.

## Read a violation

The script prints the shortest counterexample, one line per step, in the
code's words. For each step, find the code it names:

- The code cannot take that step: the model is wrong. Fix the model action.
- The code can take that step: it is a bug. Report it with the steps. Do not
  change the property or the model to make it pass.

## When the code changes

The script also lists covered files that changed since the sync commit.

1. Read the diff of each listed file.
2. If the change alters a step, update the matching action in the model. Each
   action names its Swift function. A screen file matters only when it changes
   which session method it calls, or from which state.
3. Run `mise run formal-session`.
4. Show that a property still fails on a broken model, for example
   `-- --variant dropPendingSignOutToken`.
5. Move the sync commit below to the commit that holds the checked code.

## Scope

- Bounds: 10 generation changes, 3 grants.
- One atomic step per main-actor segment between `await`s.
- Callers act as the shipped screens do: `cancelSignIn()` only during web
  sign-in, `failSignIn(_:)` during web sign-in or after `beginSignIn()` throws, `restore()` only at launch and from "Try again",
  `signOut()` only from Account and the sign-out retry.
- put.io accepts exactly the grants it issued and has not revoked. A grant
  issued to an abandoned web or device-code sign-in is out of scope.
- Not covered: account refresh ordering, preference staleness, Chromecast
  cleanup, and token handling inside `PutioSDK`.

## Coverage

Sync commit: `6813031b`

- `Packages/PutioCore/Sources/PutioCore/Session/PutioSessionStore.swift` (all session transitions)
- `Packages/PutioCore/Sources/PutioCore/Runtime/PutioRuntime.swift` (`performAuthenticatedOperation`)
- `Packages/PutioCore/Sources/PutioCore/Runtime/PutioRuntime+AccountSecurity.swift` (`endDestroyedSession` callers)
- `Apps/iOS/Sources/Session/WelcomeScreen.swift` (web sign-in, restore retry, discard)
- `Apps/iOS/Sources/App/SessionRootView.swift` (launch restore, sign-out retry)
- `Apps/iOS/Sources/Account/AccountView.swift` (sign-out)
- `Apps/tvOS/Sources/Session/TVSignIn.swift` (device-code sign-in, restore retry, discard)
- `Apps/tvOS/Sources/App/TVSessionRootView.swift` (launch restore, sign-out retry)
- `Apps/tvOS/Sources/Account/TVAccount.swift` (sign-out)
