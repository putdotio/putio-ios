import AuthenticationServices
import PutioCore
import PutioSDK
import SwiftUI

@main
struct PutioApp: App {
  private let scenario = HarnessScenario.parse(arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      Group {
        switch scenario {
        case .gallery:
          PutioComponentGallery(autoAdvanceEvery: 3)
        case .exercised:
          HarnessExerciseView()
        case .signedOut, .signedIn:
          SessionRootView(scenario: scenario)
        }
      }
      .preferredColorScheme(.dark)
      .tint(PutioTheme.Colors.accent)
    }
  }
}

// The fixed harness exercise contract: relaunch into accessibility Dynamic
// Type, write the semantic marker, and render the typography proof content.
private struct HarnessExerciseView: View {
  var body: some View {
    SignedOutProofView(
      presentation: .harnessInitialPresentation(arguments: [
        "--putio-harness-scenario", "exercised",
      ])
    )
    .dynamicTypeSize(.accessibility3)
    .onAppear {
      SignedOutPresentation.signalHarnessExercise()
    }
  }
}

private struct SessionRootView: View {
  private let scenario: HarnessScenario
  @State private var session: PutioSessionStore

  init(scenario: HarnessScenario) {
    self.scenario = scenario
    _session = State(initialValue: PutioSessionFactory.make(scenario: scenario))
  }

  var body: some View {
    Group {
      switch session.state {
      case .unknown:
        PutioLoadingStateView()
      case .authenticating:
        PutioLoadingStateView(title: "Signing in…")
      case .signedOut(let reason):
        SignInView(session: session, reason: reason)
      case .signedIn(let account):
        AccountView(
          session: session,
          account: account,
          autoSignOutAfterSeconds: scenario == .signedIn ? 5 : nil
        )
      }
    }
    .background(PutioTheme.Colors.background)
    .task {
      await session.restore()
    }
  }
}

private struct SignInView: View {
  let session: PutioSessionStore
  let reason: PutioSignedOutReason?

  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap

  var body: some View {
    VStack(spacing: contentGap) {
      Text("put.io")
        .putioFont(PutioTheme.Typography.title)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(subtitle)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(subtitleColor)
        .multilineTextAlignment(.center)
      PutioButton("Sign in", tier: .primary) {
        Task { await startSignIn() }
      }
      if case .restoreFailed = reason {
        PutioButton("Try again", icon: .arrowCounterClockwise, tier: .ghost) {
          Task { await session.restore() }
        }
      }
    }
    .padding(PutioTheme.Spacing.space4)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }

  private var subtitle: String {
    switch reason {
    case nil, .userSignedOut:
      "Sign in to continue"
    case .sessionExpired:
      "Your session expired. Sign in again."
    case .authenticationFailed(let message), .restoreFailed(let message):
      message
    }
  }

  private var subtitleColor: Color {
    switch reason {
    case .authenticationFailed, .restoreFailed, .sessionExpired:
      PutioTheme.Colors.destructive
    default:
      PutioTheme.Colors.textSecondary
    }
  }

  private func startSignIn() async {
    do {
      let request = try session.beginSignIn()
      let callbackURL = try await webAuthenticationSession.authenticate(
        using: request.url,
        callbackURLScheme: request.callbackScheme
      )
      await session.completeSignIn(callbackURL: callbackURL)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      session.cancelSignIn()
    } catch {
      session.failSignIn(error)
    }
  }
}

private struct AccountView: View {
  let session: PutioSessionStore
  let account: PutioAccount
  let autoSignOutAfterSeconds: TimeInterval?

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("Username", value: account.username)
          LabeledContent("Email", value: account.mail)
        }
        Section("Storage") {
          LabeledContent("Used", value: byteText(account.disk.used))
          LabeledContent("Available", value: byteText(account.disk.available))
          LabeledContent("Total", value: byteText(account.disk.size))
        }
        Section {
          Button("Sign out", role: .destructive) {
            Task { await session.signOut() }
          }
        }
      }
      .navigationTitle("Account")
      .putioFont(PutioTheme.Typography.body)
    }
    .task {
      // The harness signed-in scenario records the full loop: restored
      // session, account bootstrap, then sign-out back to the sign-in screen.
      guard let autoSignOutAfterSeconds else { return }
      try? await Task.sleep(for: .seconds(autoSignOutAfterSeconds))
      guard !Task.isCancelled else { return }
      await session.signOut()
    }
  }

  private func byteText(_ bytes: Int64) -> String {
    PutioFileRowModel.sizeText(bytes: bytes)
  }
}

private struct SignedOutProofView: View {
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap

  let presentation: SignedOutPresentation

  var body: some View {
    ScrollView {
      content.padding(PutioTheme.Spacing.space4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }

  private var content: some View {
    VStack(spacing: contentGap) {
      Image(systemName: "externaldrive.fill")
        .putioIcon(PutioTheme.Icons.button)
        .foregroundStyle(PutioTheme.Colors.accent)
      Text(presentation.title)
        .putioFont(PutioTheme.Typography.title)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      ForEach(TypographyHarnessProof.hostileFilenames, id: \.self) { filename in
        Text(filename)
          .putioFont(PutioTheme.Typography.mono)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
      }
      Text(TypographyHarnessProof.numericSample)
        .putioFont(PutioTheme.Typography.numeric)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
  }
}
