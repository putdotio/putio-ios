---------------------------- MODULE PutioSession ----------------------------
(***************************************************************************)
(* PutioSessionStore (Packages/PutioCore/Sources/PutioCore/Session/        *)
(* PutioSessionStore.swift) as the shipped iOS and tvOS screens drive it.  *)
(*                                                                         *)
(* The store runs on the main actor, so the code between two `await`s is   *)
(* one atomic step here. Each `await` is a pending record in `flows`; the  *)
(* server answers flows in any order, and the app may relaunch at any      *)
(* time. Grants are put.io OAuth grants; `live` holds the ones put.io      *)
(* still accepts.                                                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  MaxGen,     \* bound on authenticationGeneration
  MaxGrants,  \* bound on grants put.io issues
  Variant     \* "shipped", or a scratch break used as a negative control

None == 0
Grants == 1..MaxGrants

VARIABLES
  state,          \* PutioSessionState; only signed-out reasons that change behavior are kept apart
  gen,            \* authenticationGeneration
  keychain,       \* PutioTokenStore contents
  sdkTok,         \* sdk.config.token
  pendingSignOut, \* pendingSignOutToken
  oauthGen,       \* pendingOAuthGeneration
  device,         \* deviceCodeSignIn
  live,           \* grants put.io accepts
  issued,         \* grants put.io has issued
  excused,        \* grants the app drops by documented design (see NoOrphanGrant)
  flows,          \* one record per suspended `await`
  launched        \* the launch restore() has run in this process

vars == <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
          live, issued, excused, flows, launched>>

Flow(k, g, t) == [k |-> k, g |-> g, t |-> t, cred |-> FALSE]

Init ==
  /\ state = "unknown"
  /\ gen = 0
  /\ keychain = None
  /\ sdkTok = None
  /\ pendingSignOut = None
  /\ oauthGen = None
  /\ device = "none"
  /\ live = {}
  /\ issued = {}
  /\ excused = {}
  /\ flows = {}
  /\ launched = FALSE

NewGrant == CHOOSE t \in Grants \ issued : \A u \in Grants \ issued : t <= u
CanIssue == issued # Grants
CanAdvance == gen < MaxGen

\* abandonPendingSignIn() followed by advanceAuthenticationGeneration().
AbandonAndAdvance ==
  /\ CanAdvance
  /\ gen' = gen + 1
  /\ oauthGen' = None
  /\ device' = "none"

\* endSession(reason), behind expireSession() and endDestroyedSession().
\* `try? tokenStore.clear()` may fail and leave the saved token behind.
EndSession ==
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ keychain' \in {None, keychain}
  /\ state' = "signedOut"

\* storeSignInToken(token, generation), entered with the flow set `rest`.
StoreToken(t, g, rest) ==
  /\ sdkTok' = t
  /\ \/ /\ keychain' = t
        /\ flows' = rest \cup {Flow("bootstrap", g, t)}
        /\ excused' = excused
     \/ /\ keychain' = keychain
        \* Best effort: `_ = try? await sdk.logout()`.
        /\ flows' = rest \cup {Flow("revokeNew", g, t)}
        /\ excused' = excused \cup {t}

-----------------------------------------------------------------------------
(* restore(): at launch (state .unknown) and from the restore-failed       *)
(* screen's "Try again". The state does not change while it validates.     *)
RestoreStart ==
  /\ \/ state = "unknown" /\ ~launched
     \/ state = "restoreFailed"
  /\ launched' = TRUE
  /\ AbandonAndAdvance
  /\ \/ /\ sdkTok' = None                      \* tokenStore.read() throws
        /\ state' = "restoreFailed"
        /\ UNCHANGED flows
     \/ /\ keychain = None
        /\ sdkTok' = None
        /\ state' = "signedOut"
        /\ UNCHANGED flows
     \/ /\ keychain # None
        /\ sdkTok' = keychain
        /\ flows' = flows \cup {Flow("validate", gen + 1, keychain)}
        /\ UNCHANGED state
  /\ UNCHANGED <<keychain, pendingSignOut, live, issued, excused>>

ValidateAnswer(f) ==
  /\ f.k = "validate"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ f.t \in live                     \* valid: bootstrap
             /\ flows' = rest \cup {Flow("bootstrap", f.g, f.t)}
             /\ UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                            live, issued, excused, launched>>
          \/ /\ f.t \notin live                  \* invalid or rejected: expireSession()
             /\ EndSession
             /\ flows' = rest
             /\ UNCHANGED <<pendingSignOut, live, issued, excused, launched>>
          \/ /\ flows' = rest                    \* transient failure keeps the token
             /\ sdkTok' = None
             /\ state' = "restoreFailed"
             /\ UNCHANGED <<gen, keychain, pendingSignOut, oauthGen, device,
                            live, issued, excused, launched>>

(* bootstrap(failure:generation:) *)
BootstrapAnswer(f) ==
  /\ f.k = "bootstrap"
  /\ LET rest == flows \ {f} IN
     \/ /\ f.t \in live                          \* account loaded: apply(account)
        /\ flows' = rest
        /\ IF f.g = gen \/ Variant = "noBootstrapGenerationGuard"
           THEN state' = "signedIn"
           ELSE UNCHANGED state
        /\ UNCHANGED <<gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                       live, issued, excused, launched>>
     \/ /\ f.t \notin live                       \* rejected: expireSession()
        /\ flows' = rest
        /\ IF f.g = gen
           THEN /\ EndSession
                /\ UNCHANGED pendingSignOut
           ELSE UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device>>
        /\ UNCHANGED <<live, issued, excused, launched>>
     \/ /\ flows' = rest                         \* transient failure: restore recovery keeps the saved token
        /\ IF f.g = gen
           THEN /\ sdkTok' = None
                /\ state' = "restoreFailed"
           ELSE UNCHANGED <<sdkTok, state>>
        /\ UNCHANGED <<gen, keychain, pendingSignOut, oauthGen, device,
                       live, issued, excused, launched>>

(* discardUnrestoredCredential(): "Sign in again" on the restore-failed    *)
(* screen. The abandoned grant is not revoked (docs/session.md).           *)
Discard ==
  /\ state = "restoreFailed"
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ \/ /\ keychain' = None
        /\ excused' = excused \cup ({keychain} \ {None})
        /\ state' = "signedOut"
     \/ /\ UNCHANGED <<keychain, excused>>   \* tokenStore.clear() throws
        /\ state' = "restoreFailed"
  /\ UNCHANGED <<pendingSignOut, live, issued, flows, launched>>

-----------------------------------------------------------------------------
(* Web sign-in on iOS: beginSignIn(), then ASWebAuthenticationSession,     *)
(* then completeSignIn(callbackURL:), cancelSignIn() or failSignIn(_:).    *)
BeginSignIn ==
  /\ state \in {"signedOut", "authFailed"}
  /\ CanAdvance
  /\ gen' = gen + 1
  /\ oauthGen' = gen + 1
  /\ state' = "authenticating"
  /\ UNCHANGED <<keychain, sdkTok, pendingSignOut, device, live, issued, excused, flows, launched>>

WebSignInPending == state = "authenticating" /\ oauthGen = gen /\ oauthGen # None

CancelOrFailSignIn ==
  /\ WebSignInPending
  /\ AbandonAndAdvance
  /\ \/ /\ state' = "signedOut"               \* cancelSignIn()
        /\ UNCHANGED sdkTok
     \/ /\ state' = "authFailed"              \* failSignIn(_:)
        /\ sdkTok' = None
  /\ UNCHANGED <<keychain, pendingSignOut, live, issued, excused, flows, launched>>

\* failSignIn(_:) after beginSignIn() threw before the web sign-in opened.
FailBeforeSignIn ==
  /\ state \in {"signedOut", "authFailed"}
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ state' = "authFailed"
  /\ UNCHANGED <<keychain, pendingSignOut, live, issued, excused, flows, launched>>

CompleteSignIn ==
  /\ WebSignInPending
  /\ oauthGen' = None
  /\ \/ /\ sdkTok' = None                     \* callback rejected
        /\ state' = "authFailed"
        /\ UNCHANGED <<keychain, live, issued, excused, flows>>
     \/ /\ CanIssue                           \* put.io granted a token
        /\ LET t == NewGrant IN
           /\ issued' = issued \cup {t}
           /\ live' = live \cup {t}
           /\ StoreToken(t, gen, flows)
           /\ UNCHANGED state
  /\ UNCHANGED <<gen, pendingSignOut, device, launched>>

-----------------------------------------------------------------------------
(* Device-code sign-in on tvOS: signInWithDeviceCode() and                 *)
(* runDeviceCodeSignIn(generation:).                                       *)
DeviceStart ==
  /\ \/ state \in {"signedOut", "authFailed"}
     \/ state = "authenticating" /\ device = "expired"
  /\ AbandonAndAdvance
  /\ device' = "fetching"
  /\ state' = "authenticating"
  /\ flows' = flows \cup {Flow("code", gen + 1, None)}
  /\ UNCHANGED <<keychain, sdkTok, pendingSignOut, live, issued, excused, launched>>

CodeAnswer(f) ==
  /\ f.k = "code"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ device' = "awaiting"
             /\ flows' = rest \cup {Flow("approval", f.g, None)}
             /\ UNCHANGED <<state, sdkTok>>
          \/ /\ device' = "none"
             /\ flows' = rest
             /\ sdkTok' = None
             /\ state' = "authFailed"
  /\ UNCHANGED <<gen, keychain, pendingSignOut, oauthGen, live, issued, excused, launched>>

\* A cancelled flow gets no grant here: put.io issuing a token to an
\* abandoned device code is out of scope.
ApprovalAnswer(f) ==
  /\ f.k = "approval"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ device' = "expired"
             /\ flows' = rest
             /\ UNCHANGED <<state, keychain, sdkTok, live, issued, excused>>
          \/ /\ device' = "none"
             /\ flows' = rest
             /\ sdkTok' = None
             /\ state' = "authFailed"
             /\ UNCHANGED <<keychain, live, issued, excused>>
          \/ /\ CanIssue
             /\ device' = "none"
             /\ LET t == NewGrant IN
                /\ issued' = issued \cup {t}
                /\ live' = live \cup {t}
                /\ StoreToken(t, f.g, rest)
             /\ UNCHANGED state
  /\ UNCHANGED <<gen, pendingSignOut, oauthGen, launched>>

RevokeNewAnswer(f) ==
  /\ f.k = "revokeNew"
  /\ flows' = flows \ {f}
  /\ live' \in {live \ {f.t}, live}           \* logout succeeds or fails
  /\ sdkTok' = IF sdkTok = f.t THEN None ELSE sdkTok
  /\ state' = IF f.g = gen THEN "authFailed" ELSE state
  /\ UNCHANGED <<gen, keychain, pendingSignOut, oauthGen, device, issued, excused, launched>>

-----------------------------------------------------------------------------
(* signOut(): from Account while signed in, and "Try signing out again".   *)
SignOutStart ==
  /\ state \in {"signedIn", "signOutFailed"}
  /\ LET pso == IF state = "signOutFailed" THEN pendingSignOut ELSE sdkTok IN
     /\ AbandonAndAdvance
     /\ \E credFailed \in BOOLEAN :
          /\ keychain' = IF credFailed THEN keychain ELSE None
          /\ IF pso # None
             THEN /\ sdkTok' = pso
                  /\ pendingSignOut' = pso
                  /\ state' = "signingOut"
                  /\ flows' = flows \cup
                       {[k |-> "logout", g |-> gen + 1, t |-> pso, cred |-> credFailed]}
             ELSE /\ sdkTok' = None
                  /\ pendingSignOut' = None
                  /\ state' = IF credFailed THEN "signOutFailed" ELSE "signedOut"
                  /\ UNCHANGED flows
  /\ UNCHANGED <<live, issued, excused, launched>>

LogoutAnswer(f) ==
  /\ f.k = "logout"
  /\ flows' = flows \ {f}
  /\ \E revocationFailed \in BOOLEAN :
       \* put.io revokes a live grant, rejects a dead one, or fails transiently.
       /\ live' = IF revocationFailed THEN live ELSE live \ {f.t}
       /\ IF f.g # gen
          THEN UNCHANGED <<state, sdkTok, pendingSignOut>>
          ELSE /\ sdkTok' = None
               /\ pendingSignOut' =
                    IF revocationFailed /\ Variant # "dropPendingSignOutToken"
                    THEN pendingSignOut ELSE None
               /\ state' = IF f.cred \/ revocationFailed THEN "signOutFailed" ELSE "signedOut"
  /\ UNCHANGED <<gen, keychain, oauthGen, device, issued, excused, launched>>

-----------------------------------------------------------------------------
(* The rest of the world.                                                  *)

\* The user revokes a grant on put.io, or changes their password.
ServerRevokes ==
  /\ \E t \in live : live' = live \ {t}
  /\ UNCHANGED <<state, gen, keychain, sdkTok, pendingSignOut, oauthGen, device,
                 issued, excused, flows, launched>>

\* PutioRuntime.performAuthenticatedOperation or refreshAccount() sees the
\* credential rejected and calls expireSession().
AuthenticatedRequestRejected ==
  /\ state = "signedIn"
  /\ sdkTok \notin live
  /\ EndSession
  /\ UNCHANGED <<pendingSignOut, live, issued, excused, flows, launched>>

\* destroyAccount(): every grant dies, then endDestroyedSession().
AccountDestroyed ==
  /\ state = "signedIn"
  /\ live' = {}
  /\ EndSession
  /\ pendingSignOut' = None
  /\ UNCHANGED <<issued, excused, flows, launched>>

\* The process ends. Sign-out intent is not persisted (docs/session.md), so a
\* pending revocation is dropped by design.
Relaunch ==
  /\ state' = "unknown"
  /\ sdkTok' = None
  /\ pendingSignOut' = None
  /\ oauthGen' = None
  /\ device' = "none"
  /\ flows' = {}
  /\ launched' = FALSE
  /\ excused' = excused \cup ({pendingSignOut} \ {None})
  /\ UNCHANGED <<gen, keychain, live, issued>>

\* One named step per kind of answer, so a counterexample names it.
ValidateDone == \E f \in flows : ValidateAnswer(f)
BootstrapDone == \E f \in flows : BootstrapAnswer(f)
CodeDone == \E f \in flows : CodeAnswer(f)
ApprovalDone == \E f \in flows : ApprovalAnswer(f)
RevokeNewDone == \E f \in flows : RevokeNewAnswer(f)
LogoutDone == \E f \in flows : LogoutAnswer(f)

Next ==
  \/ RestoreStart
  \/ Discard
  \/ BeginSignIn
  \/ CancelOrFailSignIn
  \/ FailBeforeSignIn
  \/ CompleteSignIn
  \/ DeviceStart
  \/ SignOutStart
  \/ ServerRevokes
  \/ AuthenticatedRequestRejected
  \/ AccountDestroyed
  \/ Relaunch
  \/ ValidateDone
  \/ BootstrapDone
  \/ CodeDone
  \/ ApprovalDone
  \/ RevokeNewDone
  \/ LogoutDone

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* Where the app still holds a grant it can revoke or restore later.
Held ==
  ({keychain, pendingSignOut} \cup {f.t : f \in flows}
    \cup (IF state = "signedIn" THEN {sdkTok} ELSE {})) \ {None}

\* Every grant put.io still accepts stays in the app's hands until it is
\* revoked, except where docs/session.md drops it on purpose: the user
\* discards an unrestorable credential, a best-effort revocation of an
\* unsaved grant fails, or the app quits with a sign-out revocation pending.
NoOrphanGrant == live \subseteq Held \cup excused

\* Signed in means the session's token is the saved one, so a relaunch
\* restores the same session.
SignedInIsSaved == state = "signedIn" => (sdkTok # None /\ keychain = sdkTok)

TypeOK ==
  /\ state \in {"unknown", "signedOut", "restoreFailed", "authFailed", "authenticating",
                "signedIn", "signingOut", "signOutFailed"}
  /\ gen \in 0..MaxGen
  /\ keychain \in Grants \cup {None}
  /\ sdkTok \in Grants \cup {None}
  /\ pendingSignOut \in Grants \cup {None}
  /\ device \in {"none", "fetching", "awaiting", "expired"}
  /\ live \subseteq issued
=============================================================================
