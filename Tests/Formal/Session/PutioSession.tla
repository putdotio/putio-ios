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
\* .signedOut(.restoreFailed(cause, message:)), one state per cause.
RestoreFailed == {"restoreStorage", "restoreCheck"}

VARIABLES
  state,          \* PutioSessionState; only signed-out reasons that change behavior are kept apart
  gen,            \* authenticationGeneration
  keychain,       \* PutioTokenStore contents
  sdkTok,         \* sdk.config.token
  intent,         \* PutioSignOutIntentStore: a sign-out has not finished its cleanup
  oauthGen,       \* pendingOAuthGeneration
  device,         \* deviceCodeSignIn
  live,           \* grants put.io accepts
  issued,         \* grants put.io has issued
  excused,        \* grants the app drops by documented design (see NoOrphanGrant)
  flows,          \* one record per suspended `await`
  launched        \* the launch restore() has run in this process

vars == <<state, gen, keychain, sdkTok, intent, oauthGen, device,
          live, issued, excused, flows, launched>>

Flow(k, g, t) == [k |-> k, g |-> g, t |-> t]

Init ==
  /\ state = "unknown"
  /\ gen = 0
  /\ keychain = None
  /\ sdkTok = None
  /\ intent = FALSE
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

\* abandonPendingSignIn() followed by advanceAuthenticationGeneration(),
\* leaving device-code sign-in in `next`.
AdvanceWithDevice(next) ==
  /\ CanAdvance
  /\ gen' = gen + 1
  /\ oauthGen' = None
  /\ device' = next

AbandonAndAdvance == AdvanceWithDevice("none")

\* expireSession().
\* `try? tokenStore.clear()` may fail and leave the saved token behind.
EndSession ==
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ keychain' \in {None, keychain}
  /\ state' = "signedOut"

\* storeSignInToken(token, generation), entered with the flow set `rest`.
\* A saved token replaces the credential an unfinished sign-out kept for
\* revocation, and ends that sign-out's cleanup.
StoreToken(t, g, rest) ==
  /\ sdkTok' = t
  /\ \/ /\ keychain' = t
        /\ intent' = FALSE
        /\ flows' = rest \cup {Flow("bootstrap", g, t)}
        /\ excused' = excused \cup (IF intent THEN {keychain} \ {None, t} ELSE {})
     \/ /\ UNCHANGED <<keychain, intent>>
        \* Best effort: `_ = try? await sdk.logout()`.
        /\ flows' = rest \cup {Flow("revokeNew", g, t)}
        /\ excused' = excused \cup {t}

-----------------------------------------------------------------------------
(* restore(): at launch (state .unknown) and from the restore-failed       *)
(* screen's "Try again". The state does not change while it validates.     *)
(* With the sign-out intent set it runs finishSignOut(token:generation:)   *)
(* on the saved credential instead.                                        *)
RestoreStart ==
  /\ \/ state = "unknown" /\ ~launched
     \/ state \in RestoreFailed
  /\ launched' = TRUE
  /\ AbandonAndAdvance
  /\ IF intent /\ Variant # "restoreIgnoresSignOutIntent"
     THEN \/ /\ sdkTok' = None                 \* tokenStore.read() throws
             /\ state' = "signedOut"
             /\ UNCHANGED <<keychain, intent, flows>>
          \/ /\ keychain # None                \* revoke the saved credential
             /\ sdkTok' = keychain
             /\ flows' = flows \cup {Flow("logout", gen + 1, keychain)}
             /\ UNCHANGED <<state, keychain, intent>>
          \/ /\ keychain = None                \* nothing to revoke: tokenStore.clear()
             /\ sdkTok' = None
             /\ state' = "signedOut"
             /\ intent' \in {FALSE, TRUE}
             /\ UNCHANGED <<keychain, flows>>
     ELSE /\ UNCHANGED <<keychain, intent>>
          /\ \/ /\ sdkTok' = None                \* tokenStore.read() throws
                /\ state' = "restoreStorage"
                /\ UNCHANGED flows
             \/ /\ keychain = None
                /\ sdkTok' = None
                /\ state' = "signedOut"
                /\ UNCHANGED flows
             \/ /\ keychain # None
                /\ sdkTok' = keychain
                /\ flows' = flows \cup {Flow("validate", gen + 1, keychain)}
                /\ UNCHANGED state
  /\ UNCHANGED <<live, issued, excused>>

ValidateAnswer(f) ==
  /\ f.k = "validate"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ f.t \in live                     \* valid: bootstrap
             /\ flows' = rest \cup {Flow("bootstrap", f.g, f.t)}
             /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                            live, issued, excused, launched>>
          \/ /\ f.t \notin live                  \* invalid or rejected: expireSession()
             /\ EndSession
             /\ flows' = rest
             /\ UNCHANGED <<intent, live, issued, excused, launched>>
          \/ /\ flows' = rest                    \* transient failure keeps the token
             /\ sdkTok' = None
             /\ state' = "restoreCheck"
             /\ UNCHANGED <<gen, keychain, intent, oauthGen, device,
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
        /\ UNCHANGED <<gen, keychain, sdkTok, intent, oauthGen, device,
                       live, issued, excused, launched>>
     \/ /\ f.t \notin live                       \* rejected: expireSession()
        /\ flows' = rest
        /\ IF f.g = gen
           THEN /\ EndSession
                /\ UNCHANGED intent
           ELSE UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device>>
        /\ UNCHANGED <<live, issued, excused, launched>>
     \/ /\ flows' = rest                         \* transient failure: restore recovery keeps the saved token
        /\ IF f.g = gen
           THEN /\ sdkTok' = None
                /\ state' = "restoreCheck"
           ELSE UNCHANGED <<sdkTok, state>>
        /\ UNCHANGED <<gen, keychain, intent, oauthGen, device,
                       live, issued, excused, launched>>

(* discardUnrestoredCredential(): "Sign in again" on the restore-failed    *)
(* screen. The abandoned grant is not revoked (docs/session.md).           *)
Discard ==
  /\ state \in RestoreFailed
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ \/ /\ keychain' = None
        /\ excused' = excused \cup ({keychain} \ {None})
        /\ state' = "signedOut"
     \/ /\ UNCHANGED <<keychain, excused>>   \* tokenStore.clear() throws
        /\ state' = "restoreStorage"
  /\ UNCHANGED <<intent, live, issued, flows, launched>>

-----------------------------------------------------------------------------
(* Web sign-in on iOS: beginSignIn(), then ASWebAuthenticationSession,     *)
(* then completeSignIn(callbackURL:), cancelSignIn() or failSignIn(_:).    *)
BeginSignIn ==
  /\ state \in {"signedOut", "authFailed"}
  /\ CanAdvance
  /\ gen' = gen + 1
  /\ oauthGen' = gen + 1
  /\ state' = "authenticating"
  /\ UNCHANGED <<keychain, sdkTok, intent, device, live, issued, excused, flows, launched>>

WebSignInPending == state = "authenticating" /\ oauthGen = gen /\ oauthGen # None

CancelOrFailSignIn ==
  /\ WebSignInPending
  /\ AbandonAndAdvance
  /\ \/ /\ state' = "signedOut"               \* cancelSignIn()
        /\ UNCHANGED sdkTok
     \/ /\ state' = "authFailed"              \* failSignIn(_:)
        /\ sdkTok' = None
  /\ UNCHANGED <<keychain, intent, live, issued, excused, flows, launched>>

\* failSignIn(_:) after beginSignIn() threw before the web sign-in opened.
FailBeforeSignIn ==
  /\ state \in {"signedOut", "authFailed"}
  /\ AbandonAndAdvance
  /\ sdkTok' = None
  /\ state' = "authFailed"
  /\ UNCHANGED <<keychain, intent, live, issued, excused, flows, launched>>

CompleteSignIn ==
  /\ WebSignInPending
  /\ oauthGen' = None
  /\ \/ /\ sdkTok' = None                     \* callback rejected
        /\ state' = "authFailed"
        /\ UNCHANGED <<keychain, intent, live, issued, excused, flows>>
     \/ /\ CanIssue                           \* put.io granted a token
        /\ LET t == NewGrant IN
           /\ issued' = issued \cup {t}
           /\ live' = live \cup {t}
           /\ StoreToken(t, gen, flows)
           /\ UNCHANGED state
  /\ UNCHANGED <<gen, device, launched>>

-----------------------------------------------------------------------------
(* Device-code sign-in on tvOS: signInWithDeviceCode() and                 *)
(* runDeviceCodeSignIn(generation:).                                       *)
DeviceStart ==
  /\ \/ state \in {"signedOut", "authFailed"}
     \/ state = "authenticating" /\ device = "expired"
  /\ AdvanceWithDevice("fetching")
  /\ state' = "authenticating"
  /\ flows' = flows \cup {Flow("code", gen + 1, None)}
  /\ UNCHANGED <<keychain, sdkTok, intent, live, issued, excused, launched>>

CodeAnswer(f) ==
  /\ f.k = "code"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ device' = "awaiting"
             /\ flows' = rest \cup {Flow("approval", f.g, None)}
             /\ UNCHANGED <<state, sdkTok>>
          \/ /\ device' = "none"
             /\ flows' = rest
             /\ sdkTok' = None
             /\ state' = "authFailed"
  /\ UNCHANGED <<gen, keychain, intent, oauthGen, live, issued, excused, launched>>

\* A cancelled flow gets no grant here: put.io issuing a token to an
\* abandoned device code is out of scope.
ApprovalAnswer(f) ==
  /\ f.k = "approval"
  /\ LET rest == flows \ {f} IN
     IF f.g # gen
     THEN /\ flows' = rest
          /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                         live, issued, excused, launched>>
     ELSE \/ /\ device' = "expired"
             /\ flows' = rest
             /\ UNCHANGED <<state, keychain, intent, sdkTok, live, issued, excused>>
          \/ /\ device' = "none"
             /\ flows' = rest
             /\ sdkTok' = None
             /\ state' = "authFailed"
             /\ UNCHANGED <<keychain, intent, live, issued, excused>>
          \/ /\ CanIssue
             /\ device' = "none"
             /\ LET t == NewGrant IN
                /\ issued' = issued \cup {t}
                /\ live' = live \cup {t}
                /\ StoreToken(t, f.g, rest)
             /\ UNCHANGED state
  /\ UNCHANGED <<gen, oauthGen, launched>>

RevokeNewAnswer(f) ==
  /\ f.k = "revokeNew"
  /\ flows' = flows \ {f}
  /\ live' \in {live \ {f.t}, live}           \* logout succeeds or fails
  /\ sdkTok' = IF sdkTok = f.t THEN None ELSE sdkTok
  /\ state' = IF f.g = gen THEN "authFailed" ELSE state
  /\ UNCHANGED <<gen, keychain, intent, oauthGen, device, issued, excused, launched>>

-----------------------------------------------------------------------------
(* signOut(): from Account while signed in. The intent persists before     *)
(* cleanup starts; finishSignOut(token:generation:) revokes, then removes  *)
(* the credential, and both answers land on the welcome.                   *)
SignOutStart ==
  /\ state = "signedIn"
  /\ sdkTok # None                               \* SignedInIsSaved
  /\ AbandonAndAdvance
  /\ intent' = TRUE
  /\ state' = "signingOut"
  /\ keychain' = IF Variant = "removeBeforeRevoking" THEN None ELSE keychain
  /\ flows' = flows \cup {Flow("logout", gen + 1, sdkTok)}
  /\ UNCHANGED <<sdkTok, live, issued, excused, launched>>

LogoutAnswer(f) ==
  /\ f.k = "logout"
  /\ flows' = flows \ {f}
  /\ \E revoked \in BOOLEAN :
       \* put.io revokes a live grant, rejects a dead one, or fails transiently.
       /\ live' = IF revoked THEN live \ {f.t} ELSE live
       /\ IF f.g # gen
          THEN UNCHANGED <<state, sdkTok, keychain, intent>>
          ELSE /\ sdkTok' = None
               /\ state' = "signedOut"
               /\ IF revoked
                  THEN \/ /\ keychain' = None
                          /\ intent' = FALSE
                       \/ UNCHANGED <<keychain, intent>>   \* tokenStore.clear() throws
                  ELSE UNCHANGED <<keychain, intent>>
  /\ UNCHANGED <<gen, oauthGen, device, issued, excused, launched>>

-----------------------------------------------------------------------------
(* The rest of the world.                                                  *)

\* The user revokes a grant on put.io, or changes their password.
ServerRevokes ==
  /\ \E t \in live : live' = live \ {t}
  /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                 issued, excused, flows, launched>>

\* PutioRuntime.performAuthenticatedOperation or refreshAccount() sees the
\* credential rejected and calls expireSession().
AuthenticatedRequestRejected ==
  /\ state = "signedIn"
  /\ sdkTok \notin live
  /\ EndSession
  /\ UNCHANGED <<intent, live, issued, excused, flows, launched>>

\* The user destroys the account on put.io: every grant dies.
AccountDestroyed ==
  /\ live # {}
  /\ live' = {}
  /\ UNCHANGED <<state, gen, keychain, sdkTok, intent, oauthGen, device,
                 issued, excused, flows, launched>>

\* The process ends. The keychain and the sign-out intent persist.
Relaunch ==
  /\ state' = "unknown"
  /\ sdkTok' = None
  /\ oauthGen' = None
  /\ device' = "none"
  /\ flows' = {}
  /\ launched' = FALSE
  /\ UNCHANGED <<gen, keychain, intent, live, issued, excused>>

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
  ({keychain} \cup {f.t : f \in flows}
    \cup (IF state = "signedIn" THEN {sdkTok} ELSE {})) \ {None}

\* Every grant put.io still accepts stays in the app's hands until it is
\* revoked, except where docs/session.md drops it on purpose: the user
\* discards an unrestorable credential, a best-effort revocation of an
\* unsaved grant fails, or a new sign-in replaces the credential an
\* unfinished sign-out kept for revocation.
NoOrphanGrant == live \subseteq Held \cup excused

\* Signed in means the session's token is the saved one, so a relaunch
\* restores the same session.
SignedInIsSaved == state = "signedIn" => (sdkTok # None /\ keychain = sdkTok)

\* A sign-out that did not finish never brings the account back.
PendingSignOutNeverSignedIn == intent => state # "signedIn"

\* Session-check recovery keeps the credential that "Try again" restores.
SessionCheckKeepsCredential == state = "restoreCheck" => keychain # None

TypeOK ==
  /\ state \in {"unknown", "signedOut", "restoreStorage", "restoreCheck", "authFailed",
                "authenticating", "signedIn", "signingOut"}
  /\ gen \in 0..MaxGen
  /\ keychain \in Grants \cup {None}
  /\ sdkTok \in Grants \cup {None}
  /\ intent \in BOOLEAN
  /\ device \in {"none", "fetching", "awaiting", "expired"}
  /\ live \subseteq issued
=============================================================================
