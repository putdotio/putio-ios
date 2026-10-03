import PutioCore
import SwiftUI

struct TVSessionRootView: View {
  private let scenario: HarnessScenario
  @State private var runtime: PutioRuntime

  init(scenario: HarnessScenario) {
    self.scenario = scenario
    _runtime = State(initialValue: PutioRuntimeFactory.make(scenario: scenario))
  }

  var body: some View {
    Group {
      switch runtime.session.state {
      case .unknown:
        PutioLoadingStateView()
      case .signedOut, .authenticating:
        TVSignInView(session: runtime.session)
      case .signingOut:
        PutioLoadingStateView(title: "Signing out…")
      case .signOutFailed(let failure):
        TVSignOutFailureView(session: runtime.session, failure: failure)
      case .signedIn(let account):
        TVSignedInShell(runtime: runtime, account: account)
          .id(account.id)
      }
    }
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    #if DEBUG
      .modifier(
        HarnessLiveSessionProbe(
          session: runtime.session,
          tokenStore: scenario == .live ? PutioRuntimeFactory.liveTokenStore : nil))
    #endif
    .task {
      await runtime.session.restore()
    }
  }
}

// MARK: - Sign in

/// What the code screen shows, derived from the session store so the view
/// owns no flow state of its own.
enum TVSignInPhase: Equatable {
  case fetchingCode
  case awaitingApproval(code: String)
  case expired(code: String)
  case failed(message: String, canRetryRestore: Bool)

  init(state: PutioSessionState, deviceCodeSignIn: PutioDeviceCodeSignInState?) {
    switch state {
    case .signedOut(.authenticationFailed(let message)):
      self = .failed(message: message, canRetryRestore: false)
    case .signedOut(.restoreFailed(let message)):
      self = .failed(message: message, canRetryRestore: true)
    case .authenticating:
      switch deviceCodeSignIn {
      case .awaitingApproval(let code): self = .awaitingApproval(code: code)
      case .expired(let code): self = .expired(code: code)
      case .fetchingCode, nil: self = .fetchingCode
      }
    default:
      self = .fetchingCode
    }
  }
}

private struct TVSignInView: View {
  let session: PutioSessionStore

  var body: some View {
    TVSignInScreen(
      phase: TVSignInPhase(state: session.state, deviceCodeSignIn: session.deviceCodeSignIn),
      sessionExpired: session.state == .signedOut(.sessionExpired),
      requestCode: { Task { await session.signInWithDeviceCode() } },
      retryRestore: { Task { await session.restore() } },
      discardCredential: { session.discardUnrestoredCredential() }
    )
    // A fresh signed-out screen asks for a code on its own; failures wait for
    // an explicit retry so an unreachable API cannot loop.
    .onChange(of: startsAutomatically, initial: true) { _, starts in
      if starts { Task { await session.signInWithDeviceCode() } }
    }
  }

  private var startsAutomatically: Bool {
    switch session.state {
    case .signedOut(nil), .signedOut(.userSignedOut), .signedOut(.sessionExpired): true
    default: false
    }
  }
}

struct TVSignInScreen: View {
  let phase: TVSignInPhase
  var sessionExpired = false
  let requestCode: () -> Void
  let retryRestore: () -> Void
  var discardCredential: () -> Void = {}

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      Text("put.io")
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      if sessionExpired {
        Text("Your session expired. Sign in again.")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
      }
      VStack(spacing: PutioTheme.TV.Spacing.xs) {
        Text("On your phone or computer, go to")
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        Text("put.io/link")
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.Colors.accent)
        Text("and enter this code")
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
      .multilineTextAlignment(.center)
      codeBlock
      status
    }
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private var codeBlock: some View {
    Group {
      switch phase {
      case .awaitingApproval(let code):
        codeText(code, color: PutioTheme.TV.Colors.textPrimary)
      case .expired(let code):
        codeText(code, color: PutioTheme.TV.Colors.textTertiary)
          .accessibilityIdentifier("auth.device-code")
          .accessibilityValue(code)
      case .fetchingCode, .failed:
        codeText("·····", color: PutioTheme.TV.Colors.textTertiary)
      }
    }
    .padding(.vertical, PutioTheme.TV.Spacing.small)
    .padding(.horizontal, PutioTheme.TV.Spacing.large)
    .background(
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
        .fill(PutioTheme.Colors.surface)
    )
  }

  private func codeText(_ code: String, color: Color) -> some View {
    Text(code)
      .putioFont(PutioTabularFontRole(base: PutioTheme.TV.Typography.heading))
      .tracking(PutioTheme.TV.Spacing.small)
      .foregroundStyle(color)
      .accessibilityIdentifier("auth.device-code")
      .accessibilityValue(code)
  }

  @ViewBuilder
  private var status: some View {
    switch phase {
    case .fetchingCode:
      TVSignInStatus(text: "Getting a code…", identifier: "auth.fetching-code")
    case .awaitingApproval:
      TVSignInStatus(text: "Waiting for approval…", identifier: "auth.awaiting-approval")
    case .expired:
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Text("This code expired.")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("auth.code-expired")
        PutioButton("Get new code", tier: .primary) {
          requestCode()
        }
        .accessibilityIdentifier("auth.new-code")
      }
    case .failed(let message, let canRetryRestore):
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Text(message)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("auth.failure")
        PutioButton("Try again", tier: .primary) {
          canRetryRestore ? retryRestore() : requestCode()
        }
        .accessibilityIdentifier("auth.retry")
        if canRetryRestore {
          // Abandoning the saved sign-in is only ever the user's choice; a
          // transient failure must not cost a valid session.
          PutioButton("Sign in again", tier: .secondary) {
            discardCredential()
          }
          .accessibilityIdentifier("auth.discard-credential")
          Text("Signing in again removes the saved sign-in from this Apple TV.")
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .multilineTextAlignment(.center)
        }
      }
    }
  }
}

private struct TVSignInStatus: View {
  let text: String
  let identifier: String

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      ProgressView()
      Text(text)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityIdentifier(identifier)
    }
  }
}

private struct TVSignOutFailureView: View {
  let session: PutioSessionStore
  let failure: PutioSignOutFailure

  var body: some View {
    PutioErrorStateView(
      title: failure.title,
      message: failure.message,
      retryTitle: failure.retryTitle,
      retryIdentifier: "auth.retry-sign-out"
    ) {
      Task { await session.signOut() }
    }
    .tvOverscanPadding()
  }
}
