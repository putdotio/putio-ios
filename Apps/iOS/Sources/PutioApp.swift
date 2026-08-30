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
    .overlay(alignment: .bottomTrailing) {
      if scenario == .filesBrowser {
        HarnessJourneyCaptureGate(
          shouldStart: runtimeProofCanStartCapture,
          shouldComplete: runtimeProofCanCompleteCapture,
          preservesRecordingAcrossRelaunch: true
        )
      }
    }
    .task {
      await runtime.session.restore()
    }
  }

  private var runtimeProofCanStartCapture: Bool {
    if case .signedOut(nil) = runtime.session.state { return true }
    return false
  }

  private var runtimeProofCanCompleteCapture: Bool {
    if case .signedOut(.userSignedOut) = runtime.session.state { return true }
    return false
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
  @State private var selectedVideoRoute: PutioFileRoute?
  @State private var harnessPlaybackAttempt = 0

  var body: some View {
    TabView {
      Tab {
        FilesBrowserView(
          runtime: runtime,
          onFileSelected: { route in selectFile(route) }
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
          AccountView(session: runtime.session, account: account)
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
    .fullScreenCover(item: $selectedVideoRoute) { route in
      PutioVideoPlaybackView(
        route: route
      ) { fileID in
        try await resolvePlaybackSource(fileID: fileID)
      }
    }
    .overlay(alignment: .topLeading) {
      if scenario == .filesBrowser, let selectedFileRoute {
        HarnessFileSelectionProbe(route: selectedFileRoute)
      }
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
    selectedVideoRoute = route.videoPlaybackRoute
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
      if harnessPlaybackAttempt == 1 {
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
      if harnessPlaybackAttempt == 1 {
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

#if DEBUG
  private enum HarnessPlaybackFixtureError: Error {
    case invalidResource
    case missingResource
  }
#endif

private struct HarnessJourneyCaptureGate: View {
  let shouldStart: Bool
  let shouldComplete: Bool
  var preservesRecordingAcrossRelaunch = false

  @State private var recordingStarted = false
  @State private var captureCompleted = false

  var body: some View {
    ZStack {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journey capture recording")
        .accessibilityIdentifier("journey.capture-recording")
        .accessibilityHidden(!recordingStarted)
        .allowsHitTesting(false)
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journey capture complete")
        .accessibilityIdentifier("journey.capture-complete")
        .accessibilityHidden(!captureCompleted)
        .allowsHitTesting(false)
      if shouldComplete, !captureCompleted {
        Button {
          captureCompleted = true
          signalCaptureComplete()
        } label: {
          Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Finish journey capture")
        .accessibilityIdentifier("journey.capture-finish")
      }
    }
    .task(id: shouldStart) {
      let fileManager = FileManager.default
      let readyMarker = fileManager.temporaryDirectory.appending(
        path: "putio-harness-journey-ready"
      )
      let recordingMarker = fileManager.temporaryDirectory.appending(
        path: "putio-harness-journey-recording"
      )
      let completeMarker = fileManager.temporaryDirectory.appending(
        path: "putio-harness-journey-complete"
      )
      if preservesRecordingAcrossRelaunch,
        fileManager.fileExists(atPath: recordingMarker.path)
      {
        recordingStarted = true
        return
      }
      for marker in [readyMarker, recordingMarker, completeMarker] {
        try? fileManager.removeItem(at: marker)
      }
      guard shouldStart else {
        return
      }
      try? Data().write(to: readyMarker, options: .atomic)

      while !Task.isCancelled {
        if fileManager.fileExists(atPath: recordingMarker.path) {
          recordingStarted = true
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func signalCaptureComplete() {
    let marker = FileManager.default.temporaryDirectory.appending(
      path: "putio-harness-journey-complete"
    )
    try? Data().write(to: marker, options: .atomic)
  }
}

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

private struct AccountView: View {
  let session: PutioSessionStore
  let account: PutioAccountSnapshot

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
        }
        Section {
          Button("Sign out", role: .destructive) {
            Task { await session.signOut() }
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
