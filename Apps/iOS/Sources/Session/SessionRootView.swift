import PutioCore
import SwiftUI

struct SessionRootView: View {
  private let scenario: HarnessScenario
  @State private var runtime: PutioRuntime
  @State private var cast: PutioCastModel
  @State private var deepLinks = PutioDeepLinkModel()

  init(scenario: HarnessScenario) {
    self.scenario = scenario
    let runtime = PutioRuntimeFactory.make(scenario: scenario)
    _runtime = State(initialValue: runtime)
    _cast = State(
      initialValue: PutioCastControllerFactory.makeModel(runtime: runtime, scenario: scenario))
  }

  var body: some View {
    Group {
      switch runtime.session.state {
      case .unknown:
        PutioLoadingStateView()
      case .signingOut:
        PutioLoadingStateView(title: "Signing out…")
      case .signOutFailed(let failure):
        SignOutFailureView(session: runtime.session, failure: failure)
      case .signedOut, .authenticating:
        // One branch keeps the welcome screen mounted under the browser
        // sheet instead of swapping in a loading screen.
        SignInView(session: runtime.session, scenario: scenario)
      case .signedIn(let account):
        MainTabView(
          runtime: runtime,
          cast: cast,
          account: account,
          deepLinks: deepLinks,
          scenario: scenario,
          autoSignOutAfterSeconds: scenario == .signedIn
            && !PutioRuntimeFactory.usesSignOutFailureFixture(scenario: scenario) ? 5 : nil
        )
        .id(account.id)
      }
    }
    .background(PutioTheme.Colors.background)
    .onOpenURL { deepLinks.receive($0) }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { deepLinks.receive(url) }
    }
    .onChange(of: runtime.session.state, initial: true) { previous, state in
      deepLinks.updateSession(state)
      if case .signedIn(let previousAccount) = previous {
        if case .signedIn(let currentAccount) = state, previousAccount.id == currentAccount.id {
          return
        }
        // The root survives shell removal, including failed sign-out and expiry.
        cast.disconnect()
      }
      if case .signedIn = state {
        cast = PutioCastControllerFactory.makeModel(runtime: runtime, scenario: scenario)
      }
    }
    #if DEBUG
      .modifier(
        HarnessLiveSessionProbe(
          session: runtime.session,
          tokenStore: scenario == .live ? PutioRuntimeFactory.liveTokenStore : nil))
    #endif
    .overlay {
      #if DEBUG
        if scenario == .filesBrowser, let controller = cast.harnessController {
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Cast receiver")
            .accessibilityValue(
              "connected=\(controller.connection.isConnected);loaded=\(controller.loaded != nil)"
            )
            .accessibilityIdentifier("cast.receiver-state")
            .allowsHitTesting(false)
        }
      #endif
    }
    .task(id: deepLinks.request) {
      guard case .signedIn(let account) = runtime.session.state else { return }
      deepLinks.startResolving(historyEnabled: account.historyEnabled) {
        try await runtime.getFile(fileID: $0)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { deepLinks.presentsStatus },
        set: { if !$0 { deepLinks.cancel() } }
      )
    ) {
      NavigationStack {
        Group {
          if let failure = deepLinks.failure {
            PutioErrorStateView(
              title: "Cannot open link", message: failure.message,
              retryTitle: failure.canRetry ? "Try again" : nil,
              retryIdentifier: "link.retry",
              retry: failure.canRetry ? { deepLinks.retry() } : nil
            )
          } else {
            PutioLoadingStateView(title: "Opening link")
              .accessibilityIdentifier("link.loading")
          }
        }
        .putioContentBackground()
        .navigationTitle("Open link")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { deepLinks.cancel() }
              .accessibilityIdentifier("link.close")
          }
        }
      }
      .preferredColorScheme(.dark)
    }
    .task {
      await runtime.session.restore()
    }
  }
}

private struct SignOutFailureView: View {
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
  }
}
