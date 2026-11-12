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
