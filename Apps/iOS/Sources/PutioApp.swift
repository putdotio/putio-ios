import AVFoundation
import AuthenticationServices
import PutioCore
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
        case .signedOut, .signedIn, .filesBrowser:
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
      case .authenticating:
        PutioLoadingStateView(title: "Signing in…")
      case .signingOut:
        PutioLoadingStateView(title: "Signing out…")
      case .signedOut(let reason):
        SignInView(session: runtime.session, reason: reason, scenario: scenario)
      case .signedIn(let account):
        MainTabView(
          runtime: runtime,
          account: account,
          scenario: scenario,
          autoSignOutAfterSeconds: scenario == .signedIn ? 5 : nil
        )
      }
    }
    .background(PutioTheme.Colors.background)
    .task {
      await runtime.session.restore()
    }
  }
}

private struct SignInView: View {
  let session: PutioSessionStore
  let reason: PutioSignedOutReason?
  let scenario: HarnessScenario

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
      .accessibilityIdentifier("auth.sign-in")
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
      #if DEBUG
        if scenario == .filesBrowser {
          let callbackURL = try PutioRuntimeFactory.runtimeProofCallback(for: request)
          await session.completeSignIn(callbackURL: callbackURL)
          return
        }
      #endif
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

// The iOS 26 shell (ios-s00, ios-e10): a stock TabView whose floating glass
// capsule, shrink-on-scroll, and separate Search capsule are all owned by the
// OS. put.io supplies the tint on the selected tab and the Phosphor glyphs.
private struct MainTabView: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let scenario: HarnessScenario
  let autoSignOutAfterSeconds: TimeInterval?

  @State private var searchText = ""
  @State private var selectedFileRoute: PutioFileRoute?
  @State private var selectedVideoRoute: PutioVideoRoute?
  @State private var harnessPlaybackAttempt = 0
  @State private var harnessReportedPosition: (fileID: PutioFileID, seconds: Int)?
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var folderRefreshRequests = PutioFolderRefreshRequests()
  @State private var presentedVideoRoute: PutioVideoRoute?

  var body: some View {
    TabView {
      Tab {
        FilesBrowserView(
          runtime: runtime,
          trashEnabled: account.trashEnabled,
          onFileSelected: { route in selectFile(route) },
          refreshRequests: folderRefreshRequests
        )
      } label: {
        Label {
          Text("Files")
        } icon: {
          Image(putioIcon: .folderFill)
        }
      }
      Tab {
        NavigationStack {
          PutioEmptyStateView(
            icon: .arrowCircleDown,
            title: "No transfers",
            message: "Transfers you start appear here."
          )
          .navigationTitle("Transfers")
          .putioContentBackground()
        }
      } label: {
        Label {
          Text("Transfers")
        } icon: {
          Image(putioIcon: .arrowCircleDown)
        }
      }
      Tab {
        NavigationStack {
          PutioEmptyStateView(
            icon: .clockCounterClockwise,
            title: "No activity",
            message: "What happens on your account appears here."
          )
          .navigationTitle("Activity")
          .putioContentBackground()
        }
      } label: {
        Label {
          Text("Activity")
        } icon: {
          Image(putioIcon: .clockCounterClockwise)
        }
      }
      Tab {
        NavigationStack {
          AccountView(
            runtime: runtime,
            account: account,
            refreshRequests: folderRefreshRequests
          )
        }
      } label: {
        Label {
          Text("Account")
        } icon: {
          Image(putioIcon: .userCircle)
        }
      }
      Tab(role: .search) {
        NavigationStack {
          PutioEmptyStateView(
            icon: .file,
            title: "Search your files",
            message: "Find files by their stored name."
          )
          .navigationTitle("Search")
          .putioContentBackground()
          .searchable(text: $searchText, prompt: "Search in Files")
        }
      }
    }
    // Shrink-on-scroll is opt-in on iOS 26 and part of the ios-e10 treatment.
    .tabBarMinimizeBehavior(.onScrollDown)
    .accessibilityHidden(selectedVideoRoute != nil)
    .overlay {
      PutioSelectedVideoCover(route: $selectedVideoRoute) { route in
        PutioVideoPlaybackView(
          route: route,
          onDismiss: dismissPresentedVideo,
          remembersPlaybackPosition: account.rememberVideoTime,
          suggestsNextVideo: account.suggestNextVideo,
          autoplayNextVideo: account.suggestNextVideo,
          showsHarnessReadiness: scenario == .filesBrowser,
          conversionPollInterval: scenario == .filesBrowser ? .milliseconds(1_200) : .seconds(3),
          nextVideoAutoplayDelay: .seconds(5),
          positionPipeline: playbackPositionPipeline,
          reportPosition: { fileID, seconds in
            try await runtime.reportVideoPlaybackPosition(fileID: fileID, seconds: seconds)
            #if DEBUG
              if scenario == .filesBrowser {
                harnessReportedPosition = (fileID, seconds)
              }
            #endif
          },
          startConversion: { fileID in
            try await runtime.startVideoConversion(fileID: fileID)
          },
          loadConversionStatus: { fileID in
            try await runtime.videoConversionStatus(fileID: fileID)
          },
          loadNextVideo: { fileID in
            try await prepareNextVideo(
              after: fileID,
              findNext: { try await runtime.findNextVideo(after: $0) },
              waitForPendingReports: {
                await playbackPositionPipeline.waitForPendingReports(fileID: $0)
              },
              resolve: { try await resolvePlaybackSource(fileID: $0) }
            )
          },
          onPlayNext: { nextVideo in
            let nextRoute = PutioVideoRoute(nextVideo: nextVideo)
            selectedVideoRoute = nextRoute
            presentedVideoRoute = nextRoute
          },
          resolve: { fileID in
            try await resolvePlaybackSource(fileID: fileID)
          }
        )
      }
    }
    .overlay(alignment: .topLeading) {
      if scenario == .filesBrowser, let selectedFileRoute {
        HarnessFileSelectionProbe(route: selectedFileRoute)
      }
    }
    .overlay(alignment: .topTrailing) {
      #if DEBUG
        if scenario == .filesBrowser {
          ZStack {
            if let presentedVideoRoute {
              HarnessPresentedVideoProbe(route: presentedVideoRoute)
            }
            if let harnessReportedPosition {
              HarnessPlaybackPositionProbe(
                fileID: harnessReportedPosition.fileID,
                seconds: harnessReportedPosition.seconds
              )
            }
          }
        }
      #endif
    }
    .task {
      // The harness signed-in scenario records the full loop: restored
      // session, account bootstrap, then sign-out back to the sign-in screen.
      guard let autoSignOutAfterSeconds else { return }
      try? await Task.sleep(for: .seconds(autoSignOutAfterSeconds))
      guard !Task.isCancelled else { return }
      await runtime.session.signOut()
    }
  }

  private func selectFile(_ route: PutioFileRoute) {
    selectedFileRoute = route
    guard let videoRoute = route.videoPlaybackRoute else { return }
    presentVideo(videoRoute)
  }

  private func presentVideo(_ route: PutioVideoRoute) {
    selectedVideoRoute = route
    presentedVideoRoute = route
  }

  private func dismissPresentedVideo() {
    guard let dismissedRoute = selectedVideoRoute else { return }
    selectedVideoRoute = nil
    presentedVideoRoute = nil
    Task { @MainActor in
      await playbackPositionPipeline.waitForPendingReports(fileID: dismissedRoute.id)
      folderRefreshRequests.request(folderID: dismissedRoute.parentID)
    }
  }

  private func resolvePlaybackSource(fileID: PutioFileID) async throws
    -> PutioPlaybackResolution
  {
    let resolution = try await runtime.resolveVideoPlaybackSource(fileID: fileID)
    #if DEBUG
      guard scenario == .filesBrowser, case .ready(let source) = resolution else {
        return resolution
      }
      harnessPlaybackAttempt += 1
      let fixtureURL: URL
      if fileID.rawValue != 411, harnessPlaybackAttempt == 1 {
        guard
          let invalidFixture = Bundle.main.url(
            forResource: "runtime-proof-invalid",
            withExtension: "m3u8",
            subdirectory: "HarnessMedia"
          )
        else {
          throw HarnessPlaybackFixtureError.missingResource
        }
        fixtureURL = invalidFixture
      } else {
        guard
          let baseURLString = ProcessInfo.processInfo.environment[
            "PUTIO_HARNESS_MEDIA_BASE_URL"
          ],
          let baseURL = URL(string: baseURLString),
          baseURL.scheme == "http",
          baseURL.host == "127.0.0.1"
        else {
          throw HarnessPlaybackFixtureError.missingResource
        }
        fixtureURL = baseURL.appending(path: "runtime-proof.m3u8")
      }
      if fileID.rawValue != 411, harnessPlaybackAttempt == 1 {
        do {
          let tracks = try await AVURLAsset(url: fixtureURL).loadTracks(
            withMediaType: .video
          )
          guard !tracks.isEmpty else {
            throw HarnessPlaybackFixtureError.invalidResource
          }
        } catch {
          throw HarnessPlaybackFixtureError.invalidResource
        }
      }
      return .ready(
        PutioPlaybackSource(
          url: fixtureURL,
          startFromSeconds: source.startFromSeconds
        )
      )
    #else
      return resolution
    #endif
  }
}

private struct PutioSelectedVideoCover<Content: View>: View {
  @Binding var route: PutioVideoRoute?
  private let content: (PutioVideoRoute) -> Content

  init(
    route: Binding<PutioVideoRoute?>,
    @ViewBuilder content: @escaping (PutioVideoRoute) -> Content
  ) {
    _route = route
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    if let route {
      content(route)
        .id(route.id)
    }
  }
}

#if DEBUG
  private enum HarnessPlaybackFixtureError: Error {
    case invalidResource
    case missingResource
  }
#endif

private struct HarnessFileSelectionProbe: View {
  let route: PutioFileRoute

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Selected file route")
      .accessibilityValue(selectionValue)
      .accessibilityIdentifier("files.selection")
      .allowsHitTesting(false)
  }

  private var selectionValue: String {
    "id=\(route.id.rawValue);parent=\(route.item.parentID.rawValue);kind=\(kindName)"
  }

  private var kindName: String {
    switch route.item.kind {
    case .folder: "folder"
    case .video: "video"
    case .audio: "audio"
    case .image: "image"
    case .pdf: "pdf"
    case .other: "other"
    }
  }
}

#if DEBUG
  private struct HarnessPresentedVideoProbe: View {
    let route: PutioVideoRoute

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Presented video route")
        .accessibilityValue("id=\(route.id.rawValue)")
        .accessibilityIdentifier("video.presented-route")
        .allowsHitTesting(false)
    }
  }

  private struct HarnessPlaybackPositionProbe: View {
    let fileID: PutioFileID
    let seconds: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position reported")
        .accessibilityValue("id=\(fileID.rawValue);seconds=\(seconds)")
        .accessibilityIdentifier("video.position-reported")
        .allowsHitTesting(false)
    }
  }
#endif

private struct AccountView: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests

  var body: some View {
    List {
      Group {
        Section {
          LabeledContent("Username", value: account.username)
          LabeledContent("Email", value: account.email)
        }
        Section("Storage") {
          LabeledContent("Used", value: byteText(account.storage.usedBytes))
          LabeledContent("Available", value: byteText(account.storage.availableBytes))
          LabeledContent("Total", value: byteText(account.storage.totalBytes))
          NavigationLink("Trash") {
            TrashManagementView(runtime: runtime) { destinationID in
              refreshRequests.request(folderID: destinationID)
            }
          }
          .accessibilityIdentifier("account.trash")
        }
        Section {
          Button("Sign out", role: .destructive) {
            Task { await runtime.session.signOut() }
          }
          .accessibilityIdentifier("auth.sign-out")
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Account")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
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
