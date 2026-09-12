import AVFoundation
import AuthenticationServices
import PutioCore
import SwiftUI

@main
struct PutioApp: App {
  @UIApplicationDelegateAdaptor(PutioAppDelegate.self) private var appDelegate
  private let scenario = HarnessScenario.parse(arguments: ProcessInfo.processInfo.arguments)

  init() {
    // The Cast context is process-global and set once; the seeded scenario
    // drives a stub receiver instead and never touches the SDK.
    if PutioCastControllerFactory.usesGoogleCast(scenario: scenario) {
      PutioGoogleCastController.configureSharedContext(
        receiverAppID: PutioCastReceiver.appID())
    }
  }

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
      #if DEBUG
        .modifier(
          HarnessRatingLinkCapture(
            enabled: scenario == .filesBrowser
              && ProcessInfo.processInfo.arguments.contains("--putio-harness-rating-link")))
      #endif
      .preferredColorScheme(.dark)
      .tint(PutioTheme.Colors.accent)
    }
  }
}

/// iOS relaunches the app for background download events and expects the
/// completion handler back once the session has delivered them.
final class PutioAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == PutioSystemOfflineDownloadEngine.sessionIdentifier else {
      completionHandler()
      return
    }
    PutioSystemOfflineDownloadEngine.backgroundCompletion = completionHandler
    // A relaunch for download events may never reach the signed-in shell
    // that builds an engine; the session itself must exist to drain them.
    PutioSystemOfflineDownloadEngine.activateBackgroundSession()
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
  @State private var deepLinks = PutioDeepLinkModel()

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
      case .signOutFailed(let failure):
        SignOutFailureView(session: runtime.session, failure: failure)
      case .signedOut(let reason):
        SignInView(session: runtime.session, reason: reason, scenario: scenario)
      case .signedIn(let account):
        MainTabView(
          runtime: runtime,
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
    .onChange(of: runtime.session.state, initial: true) { _, state in
      deepLinks.updateSession(state)
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
      title: "Sign-out did not finish",
      message: message,
      retryTitle: "Try signing out again",
      retryIdentifier: "auth.retry-sign-out"
    ) {
      Task { await session.signOut() }
    }
  }

  private var message: String {
    switch failure {
    case .credentialRemoval:
      "Saved sign-in details could not be removed. Try again before closing the app."
    case .revocation:
      "put.io could not revoke your session. Check your connection and try again."
    case .credentialRemovalAndRevocation:
      "Saved sign-in details could not be removed and put.io could not revoke your session. Check your connection and try again before closing the app."
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
        PutioButton("Try again", icon: .arrowCounterClockwise, tier: .secondary) {
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
  let deepLinks: PutioDeepLinkModel
  let scenario: HarnessScenario
  let autoSignOutAfterSeconds: TimeInterval?

  init(
    runtime: PutioRuntime,
    account: PutioAccountSnapshot,
    deepLinks: PutioDeepLinkModel,
    scenario: HarnessScenario,
    autoSignOutAfterSeconds: TimeInterval?
  ) {
    self.runtime = runtime
    self.account = account
    self.deepLinks = deepLinks
    self.scenario = scenario
    self.autoSignOutAfterSeconds = autoSignOutAfterSeconds
    _externalPlayback = State(
      initialValue: PutioExternalPlaybackModel(
        opener: PutioExternalPlaybackOpener.make(scenario: scenario),
        resolve: { fileID in try await runtime.resolveFileDownloadSource(fileID: fileID) }
      ))
    _offlineQueue = State(
      initialValue: PutioOfflineQueueFactory.make(
        runtime: runtime, accountID: account.id, scenario: scenario))
    _cast = State(
      initialValue: PutioCastControllerFactory.makeModel(runtime: runtime, scenario: scenario))
  }

  private enum SelectedTab: Hashable { case files, downloads, history, account, search }
  @State private var selectedTab: SelectedTab = .files
  @State private var filesNavigation: PutioFilesNavigationRequest?
  @State private var accountNavigationRevision: UInt64 = 0
  @State private var selectedFileRoute: PutioFileRoute?
  @State private var selectedVideoRoute: PutioVideoRoute?
  @State private var harnessPlaybackAttempt = 0
  @State private var harnessReportedPosition: (fileID: PutioFileID, seconds: Int)?
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var folderRefreshRequests = PutioFolderRefreshRequests()
  @State private var trashReconciliation = PutioTrashReconciliation()
  @State private var historyRevision: UInt64 = 0
  @State private var presentedVideoRoute: PutioVideoRoute?
  @State private var presentedAudioRoute: PutioAudioRoute?
  @State private var presentedPreviewRoute: PutioPreviewRoute?
  @State private var presentedUnsupportedRoute: PutioUnsupportedFileRoute?
  @State private var externalPlayback: PutioExternalPlaybackModel
  @State private var offlineQueue: PutioOfflineQueue
  @State private var cast: PutioCastModel
  @State private var trackPicker: PutioOfflineTrackPickerRequest?
  @State private var offlineFailure: PutioOfflineFailure?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TabView(selection: $selectedTab) {
      Tab(value: SelectedTab.files) {
        filesBrowser
      } label: {
        Label {
          Text("Files")
        } icon: {
          Image(putioIcon: .folderFill)
        }
      }
      Tab(value: SelectedTab.downloads) {
        NavigationStack {
          PutioOfflineDownloadsView(queue: offlineQueue) { item in openOffline(item) }
        }
      } label: {
        Label {
          Text("Downloads")
        } icon: {
          Image(putioIcon: .arrowCircleDown)
        }
      }
      if account.historyEnabled {
        Tab(value: SelectedTab.history) {
          HistoryView(
            runtime: runtime,
            trashEnabled: account.trashEnabled,
            refreshRequests: folderRefreshRequests,
            onFileSelected: { route in selectFile(route) }
          )
          .id(historyRevision)
        } label: {
          Label {
            Text("History")
          } icon: {
            Image(putioIcon: .clockCounterClockwise)
          }
        }
      }
      Tab(value: SelectedTab.account) {
        NavigationStack {
          AccountView(
            runtime: runtime,
            account: account,
            refreshRequests: folderRefreshRequests,
            trashReconciliation: trashReconciliation,
            cast: cast,
            onDataCleared: { categories in
              if !categories.isDisjoint(with: [.files, .trash]) {
                folderRefreshRequests.requestAllLoadedFolders()
              }
              if categories.contains(.history) { historyRevision &+= 1 }
            },
            onAccountDestroyed: {
              // Local media belongs to an account that can never sign in again.
              offlineQueue.remove(fileIDs: offlineQueue.items.map(\.id))
            }
          )
        }
        .id(accountNavigationRevision)
      } label: {
        Label {
          Text("Account")
        } icon: {
          Image(putioIcon: .userCircle)
        }
      }
      Tab(value: SelectedTab.search, role: .search) {
        FilesSearchView(
          runtime: runtime,
          trashEnabled: account.trashEnabled,
          refreshRequests: folderRefreshRequests,
          onFileSelected: { route in selectFile(route) }
        )
      }
    }
    // Shrink-on-scroll is opt-in on iOS 26 and part of the ios-e10 treatment.
    .tabBarMinimizeBehavior(.onScrollDown)
    .modifier(PutioCastPresentation(model: cast))
    .accessibilityHidden(selectedVideoRoute != nil)
    .overlay {
      PutioSelectedVideoCover(route: $selectedVideoRoute) { route in
        videoPlayer(for: route)
      }
    }
    .sheet(item: $presentedAudioRoute) { route in
      PutioAudioPlayerView(
        route: route,
        onDismiss: { presentedAudioRoute = nil },
        onClose: { track in
          // The last track may differ from the tapped one after queue advance.
          Task { @MainActor in
            await Task.yield()
            await playbackPositionPipeline.waitForPendingReports(fileID: track.id)
            folderRefreshRequests.request(folderID: track.parentID)
          }
        },
        showsHarnessReadiness: scenario == .filesBrowser,
        positionPipeline: playbackPositionPipeline,
        reportPosition: { fileID, seconds in
          if offlineQueue.item(for: fileID)?.isPlayable == true {
            await offlineQueue.recordPosition(fileID: fileID, seconds: seconds)
          } else {
            try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
          }
        },
        resolve: { fileID in
          if let local = offlineQueue.localSource(for: fileID) { return local }
          return try await resolveAudioSource(fileID: fileID)
        },
        loadNext: { fileID in try await runtime.findNextAudio(after: fileID) }
      )
    }
    .sheet(item: $presentedPreviewRoute) { route in
      PutioPreviewView(
        route: route,
        download: { fileID in try await downloadPreview(fileID: fileID) },
        onDismiss: { presentedPreviewRoute = nil }
      )
      .preferredColorScheme(.dark)
    }
    .sheet(item: $presentedUnsupportedRoute) { route in
      PutioUnsupportedFileView(route: route, onDismiss: { presentedUnsupportedRoute = nil })
        .preferredColorScheme(.dark)
    }
    .sheet(item: $trackPicker) { request in
      PutioOfflineTrackPickerView(
        name: request.route.item.name, inventory: request.inventory,
        availableBytes: offlineQueue.unreservedBytes,
        preferredLanguages: PutioOfflineQueueFactory.preferredLanguages(scenario: scenario),
        onConfirm: { languages in
          trackPicker = nil
          enqueueDownload(
            request.route, audioLanguages: languages,
            estimatedBytes: request.inventory.estimatedBytes(selecting: languages))
        },
        onCancel: { trackPicker = nil }
      )
      .preferredColorScheme(.dark)
    }
    .alert(
      "Could not start download",
      isPresented: Binding(get: { offlineFailure != nil }, set: { if !$0 { offlineFailure = nil } })
    ) {
      Button("OK", role: .cancel) { offlineFailure = nil }
    } message: {
      Text(offlineFailure?.message ?? "")
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await offlineQueue.syncPendingPositions() }
    }
    .task {
      // A cold launch is already active, so the scene-phase change never
      // fires; sync once here as well.
      await offlineQueue.restore()
      await offlineQueue.syncPendingPositions()
    }
    .alert(
      externalPlaybackAlertTitle,
      isPresented: Binding(
        get: { externalPlayback.presentsOutcome },
        set: { if !$0 { externalPlayback.dismiss() } }
      )
    ) {
      switch externalPlayback.outcome {
      case .notInstalled:
        Button("Get VLC") { Task { await externalPlayback.openAppStore() } }
        Button("Cancel", role: .cancel) { externalPlayback.dismiss() }
      case .failed(let failure):
        if failure.canRetry {
          Button("Try again") { Task { await externalPlayback.retry() } }
        }
        Button("OK", role: .cancel) { externalPlayback.dismiss() }
      case .opened, nil:
        Button("OK", role: .cancel) { externalPlayback.dismiss() }
      }
    } message: {
      Text(externalPlaybackAlertMessage)
    }
    .overlay(alignment: .topLeading) {
      if scenario == .filesBrowser, let selectedFileRoute {
        HarnessFileSelectionProbe(route: selectedFileRoute)
      }
    }
    .overlay(alignment: .topTrailing) {
      #if DEBUG
        if scenario == .filesBrowser { harnessProbes }
      #endif
    }
    .onChange(of: deepLinks.destination, initial: true) { _, destination in
      guard let destination else { return }
      deepLinks.consumeDestination()
      dismissPresentedVideo()
      presentedAudioRoute = nil
      presentedPreviewRoute = nil
      presentedUnsupportedRoute = nil
      switch destination {
      case .files(let path, let file):
        filesNavigation = PutioFilesNavigationRequest(path: path)
        selectedTab = .files
        if let file { selectFile(file) }
      case .history:
        historyRevision &+= 1
        selectedTab = .history
      case .account:
        accountNavigationRevision &+= 1
        selectedTab = .account
      }
    }
    .onChange(of: runtime.session.folderSortsRevision) {
      folderRefreshRequests.requestAllLoadedFolders()
    }
    .onChange(of: account) { previous, current in
      PutioAccountPreferencesReconciliation.apply(
        previous: previous, current: current,
        folders: folderRefreshRequests, trash: trashReconciliation)
      if previous.id == current.id, previous.historyEnabled != current.historyEnabled {
        historyRevision &+= 1
        if !current.historyEnabled, selectedTab == .history { selectedTab = .account }
      }
    }
    .task {
      // The harness signed-in scenario records the full loop: restored
      // session, account bootstrap, then sign-out back to the sign-in screen.
      guard let autoSignOutAfterSeconds else { return }
      try? await Task.sleep(for: .seconds(autoSignOutAfterSeconds))
      guard !Task.isCancelled else { return }
      PutioFilesNavigationRestoration().clear(accountID: account.id)
      await runtime.session.signOut()
    }
  }

  private func selectFile(_ route: PutioFileRoute) {
    selectedFileRoute = route
    switch route.openAction {
    case .video(let videoRoute):
      if cast.isConnected, offlineQueue.item(for: route.id)?.isPlayable != true {
        cast.cast(videoRoute)
      } else {
        presentVideo(videoRoute)
      }
    case .audio(let audioRoute):
      presentedAudioRoute = audioRoute
    case .preview(let previewRoute):
      presentedPreviewRoute = previewRoute
    case .unsupported(let unsupportedRoute):
      presentedUnsupportedRoute = unsupportedRoute
    }
  }

  /// Multi-audio videos go through the picker; everything else queues directly.
  private func requestDownload(_ route: PutioFileRoute) async {
    let kind: PutioOfflineItem.Kind = route.item.kind == .audio ? .audio : .video
    offlineQueue.refreshStorage()
    var estimate: Int64 = route.item.sizeBytes
    var awaitsLanguages = false
    do {
      switch try await offlineQueue.inventory(fileID: route.id, kind: kind) {
      case .ready(let inventory):
        if inventory.audioOptions.count > 1 {
          trackPicker = PutioOfflineTrackPickerRequest(route: route, inventory: inventory)
          return
        }
        estimate = inventory.estimatedBytes(
          selecting: inventory.audioOptions.map(\.languageCode))
      case .needsConversion:
        // No stream to inspect yet; every language is kept after conversion.
        awaitsLanguages = true
      case .notApplicable:
        break
      }
    } catch {
      offlineFailure =
        PutioOfflineFailure.resolving(error)
        ?? PutioOfflineFailure(
          kind: .resolution, message: "The file could not be inspected. Try again.")
      return
    }
    enqueueDownload(
      route, audioLanguages: [], estimatedBytes: estimate, awaitsLanguageSelection: awaitsLanguages)
  }

  private func enqueueDownload(
    _ route: PutioFileRoute, audioLanguages: [String], estimatedBytes: Int64,
    awaitsLanguageSelection: Bool = false
  ) {
    offlineQueue.enqueue(
      fileID: route.id, parentID: route.item.parentID, name: route.item.name,
      kind: route.item.kind == .audio ? .audio : .video, audioLanguages: audioLanguages,
      estimatedBytes: estimatedBytes, awaitsLanguageSelection: awaitsLanguageSelection)
    selectedTab = .downloads
    // The seeded journey proves the queue, not the system prompt; the prompt
    // would cover the row in its screenshot.
    guard scenario != .filesBrowser else { return }
    Task { await PutioOfflineNotifications.requestPermissionIfNeeded() }
  }

  private func openOffline(_ item: PutioOfflineItem) {
    guard let source = offlineQueue.localSource(for: item.id) else { return }
    switch item.kind {
    case .video:
      presentVideo(
        PutioVideoRoute(
          id: item.id, parentID: item.parentID, title: item.name,
          initialResolution: .ready(source)))
    case .audio:
      presentedAudioRoute = PutioAudioRoute(id: item.id, parentID: item.parentID, title: item.name)
    }
  }

  private var externalPlaybackAlertTitle: String {
    switch externalPlayback.outcome {
    case .notInstalled: "VLC is not installed"
    case .failed(let failure): failure.title
    case .opened, nil: ""
    }
  }

  private var externalPlaybackAlertMessage: String {
    switch externalPlayback.outcome {
    case .notInstalled:
      "Install VLC for iOS from the App Store to stream this file there."
    case .failed(let failure): failure.message
    case .opened, nil: ""
    }
  }

  /// Previews download the whole file; the tokened URL never leaves this call.
  /// A rejected token on the raw GET is re-checked through the runtime, which
  /// signs the account out when the session really expired.
  private func downloadPreview(fileID: PutioFileID) async throws -> Data {
    let source = try await runtime.resolveFileDownloadSource(fileID: fileID)
    let url = try harnessPreviewURL(for: source) ?? source.url
    do {
      return try await PutioPreviewDownloader.download(url)
    } catch PutioRuntimeError.sessionExpired {
      _ = try await runtime.getFile(fileID: fileID)
      throw PutioRuntimeError.transient
    }
  }

  /// The seeded scenario serves local fixtures instead of api.put.io downloads.
  private func harnessPreviewURL(for source: PutioFileDownloadSource) throws -> URL? {
    #if DEBUG
      guard scenario == .filesBrowser else { return nil }
      guard
        let baseURLString = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let baseURL = URL(string: baseURLString),
        baseURL.scheme == "http",
        baseURL.host == "127.0.0.1"
      else {
        throw HarnessPlaybackFixtureError.missingResource
      }
      switch source.kind {
      case .image: return baseURL.appending(path: "runtime-proof-image.png")
      case .pdf: return baseURL.appending(path: "runtime-proof-document.pdf")
      default: return nil
      }
    #else
      return nil
    #endif
  }

  private func presentVideo(_ route: PutioVideoRoute) {
    selectedVideoRoute = route
    presentedVideoRoute = route
  }

  private var filesBrowser: some View {
    FilesBrowserView(
      runtime: runtime,
      trashEnabled: account.trashEnabled,
      accountID: account.id,
      onFileSelected: { route in selectFile(route) },
      onExternalPlayback: { route in Task { await externalPlayback.open(route) } },
      onDownload: { route in Task { await requestDownload(route) } },
      onCast: castAction,
      refreshRequests: folderRefreshRequests,
      navigationRequest: filesNavigation,
      castButton: { AnyView(PutioCastButton(model: cast)) }
    )
  }

  private func videoPlayer(for route: PutioVideoRoute) -> some View {
    PutioVideoPlaybackView(
      route: route,
      onDismiss: dismissPresentedVideo,
      preferredAudioLanguages: offlineQueue.item(for: route.id)?.isPlayable == true
        ? PutioOfflineQueueFactory.preferredLanguages(scenario: scenario) : [],
      remembersPlaybackPosition: account.rememberVideoTime,
      suggestsNextVideo: account.suggestNextVideo,
      autoplayNextVideo: account.suggestNextVideo,
      showsHarnessReadiness: scenario == .filesBrowser,
      conversionPollInterval: scenario == .filesBrowser ? .milliseconds(1_200) : .seconds(3),
      nextVideoAutoplayDelay: .seconds(5),
      positionPipeline: playbackPositionPipeline,
      reportPosition: { fileID, seconds in
        if offlineQueue.item(for: fileID)?.isPlayable == true {
          await offlineQueue.recordPosition(fileID: fileID, seconds: seconds)
        } else {
          try await runtime.reportVideoPlaybackPosition(fileID: fileID, seconds: seconds)
        }
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
        let completedRoute = selectedVideoRoute
        let nextRoute = PutioVideoRoute(nextVideo: nextVideo)
        selectedVideoRoute = nextRoute
        presentedVideoRoute = nextRoute
        // The completed video's folder shows its watched state; the
        // successor's folder is refreshed when that player is dismissed.
        if let completedRoute, completedRoute.parentID != nextRoute.parentID {
          refreshFolderAfterPlayback(completedRoute)
        }
      },
      castButton: playerCastButton,
      onCast: playerCastAction(for: route),
      resolve: { fileID in
        try await resolvePlaybackSource(fileID: fileID)
      }
    )
  }

  #if DEBUG
    private var harnessProbes: some View {
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
        HarnessExternalPlaybackProbe(requestCount: externalPlayback.openedRequestCount)
        if let reported = cast.reportedPosition {
          HarnessCastPositionProbe(fileID: reported.fileID, seconds: reported.seconds)
        }
      }
    }
  #endif

  private var playerCastButton: AnyView? {
    guard cast.showsCastButton else { return nil }
    return AnyView(PutioCastButton(model: cast))
  }

  /// Hands the video to the receiver; the local player's teardown flushes
  /// its final position first.
  private func playerCastAction(for route: PutioVideoRoute) -> (@MainActor @Sendable () -> Void)? {
    guard cast.isConnected else { return nil }
    return {
      dismissPresentedVideo()
      cast.cast(route)
    }
  }

  private var castAction: PutioFileSelection? {
    guard cast.isConnected else { return nil }
    return { route in castFile(route) }
  }

  /// Explicit "Cast" from a row: never falls back to the local player.
  private func castFile(_ route: PutioFileRoute) {
    guard let videoRoute = route.videoPlaybackRoute else { return }
    selectedFileRoute = route
    cast.cast(videoRoute)
  }

  private func dismissPresentedVideo() {
    guard let dismissedRoute = selectedVideoRoute else { return }
    selectedVideoRoute = nil
    presentedVideoRoute = nil
    refreshFolderAfterPlayback(dismissedRoute)
  }

  /// The player's final position report is enqueued by its teardown, which
  /// runs in the SwiftUI commit that removes the route. Waiting one main-actor
  /// turn before observing the pipeline makes that ordering explicit instead
  /// of relying on run-loop scheduling.
  private func refreshFolderAfterPlayback(_ route: PutioVideoRoute) {
    Task { @MainActor in
      await Task.yield()
      await playbackPositionPipeline.waitForPendingReports(fileID: route.id)
      folderRefreshRequests.request(folderID: route.parentID)
    }
  }

  private func resolveAudioSource(fileID: PutioFileID) async throws -> PutioPlaybackSource {
    let source = try await runtime.resolveAudioPlaybackSource(fileID: fileID)
    #if DEBUG
      guard scenario == .filesBrowser else { return source }
      guard
        let baseURLString = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let baseURL = URL(string: baseURLString),
        baseURL.scheme == "http",
        baseURL.host == "127.0.0.1"
      else {
        throw HarnessPlaybackFixtureError.missingResource
      }
      return PutioPlaybackSource(
        url: baseURL.appending(path: "runtime-proof-audio.m4a"),
        startFromSeconds: source.startFromSeconds
      )
    #else
      return source
    #endif
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
  /// Re-renders on every handed-off URL so the recorded summary stays current.
  private struct HarnessExternalPlaybackProbe: View {
    let requestCount: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("External playback requests")
        .accessibilityValue(HarnessExternalURLOpener.summary())
        .accessibilityIdentifier("vlc.requests")
        .allowsHitTesting(false)
    }
  }

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
  let trashReconciliation: PutioTrashReconciliation
  let cast: PutioCastModel
  let onDataCleared: @MainActor (Set<PutioAccountDataCategory>) -> Void
  let onAccountDestroyed: @MainActor () -> Void
  @State private var isRefreshingStorage = false

  var body: some View {
    List {
      Group {
        Section {
          LabeledContent("Username", value: account.username)
          LabeledContent("Email", value: account.email)
        }
        Section {
          NavigationLink("File Preferences") {
            FilePreferencesView(
              runtime: runtime,
              refreshRequests: refreshRequests,
              trashReconciliation: trashReconciliation
            )
          }
          .accessibilityIdentifier("account.file-preferences")
          NavigationLink("Playback Preferences") {
            PlaybackPreferencesView(runtime: runtime)
          }
          .accessibilityIdentifier("account.playback-preferences")
          NavigationLink("Chromecast") {
            PutioCastPreferencesView(model: cast)
          }
          .accessibilityIdentifier("account.chromecast")
          NavigationLink("Security") {
            AccountSecurityView(runtime: runtime)
          }
          .accessibilityIdentifier("account.security")
        }
        Section("Storage") {
          LabeledContent("Used", value: byteText(account.storage.usedBytes))
            .accessibilityIdentifier("account.storage-used")
          LabeledContent("Available", value: byteText(account.storage.availableBytes))
          LabeledContent("Total", value: byteText(account.storage.totalBytes))
          if runtime.session.isAccountStorageStale {
            // Stale-storage state outlives the Trash screen that caused it.
            PutioErrorStateView(
              title: PutioTrashErrorPresentation.staleStorage.title,
              message: PutioTrashErrorPresentation.staleStorage.message,
              retryTitle: isRefreshingStorage ? "Updating…" : "Update storage"
            ) {
              // Flip the flag before suspending so a second tap cannot start
              // another refresh, and only the one owner clears it.
              guard !isRefreshingStorage else { return }
              isRefreshingStorage = true
              Task {
                defer { isRefreshingStorage = false }
                _ = await runtime.refreshAccountStorage()
              }
            }
            .disabled(isRefreshingStorage)
            .accessibilityIdentifier("account.storage-retry")
          }
          NavigationLink("Trash") {
            TrashManagementView(
              runtime: runtime,
              reconciliation: trashReconciliation,
              onRestored: reconcileRestoredFile
            )
          }
          .accessibilityIdentifier("account.trash")
        }
        if let reviewURL = URL(
          string: "https://apps.apple.com/app/id1260479699?action=write-review")
        {
          Section("Support") {
            NavigationLink("About") {
              AboutView()
            }
            .accessibilityIdentifier("account.about")
            Link("Rate put.io on App Store", destination: reviewURL)
              .accessibilityIdentifier("account.rate-app")
          }
        }
        Section("Danger Zone") {
          NavigationLink("Clear Data") {
            ClearDataView(actions: .init(runtime: runtime), onCleared: onDataCleared)
          }
          .accessibilityIdentifier("account.clear-data")
          NavigationLink("Destroy Account") {
            DestroyAccountView(actions: .init(runtime: runtime), onDestroyed: onAccountDestroyed)
          }
          .accessibilityIdentifier("account.destroy-account")
        }
        Section {
          Button("Sign out", role: .destructive) {
            PutioFilesNavigationRestoration().clear(accountID: account.id)
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

  private func reconcileRestoredFile(destinationID: PutioFileID?) {
    PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
  }
}

/// Account changes can arrive after the settings screen has been dismissed,
/// including through a storage refresh following an uncertain settings write.
enum PutioAccountPreferencesReconciliation {
  @MainActor
  static func apply(
    previous: PutioAccountSnapshot, current: PutioAccountSnapshot,
    folders: PutioFolderRefreshRequests, trash: PutioTrashReconciliation
  ) {
    guard previous.id == current.id else { return }
    if previous.defaultSort != current.defaultSort || previous.trashEnabled != current.trashEnabled
    {
      folders.requestAllLoadedFolders()
    }
    if previous.trashEnabled && !current.trashEnabled {
      trash.recordEmptied()
    }
  }
}

/// Maps a Trash restore back onto the Files browser: a known destination
/// refreshes that folder; an unknown one refreshes every loaded folder.
enum PutioRestoredFileReconciliation {
  @MainActor
  static func apply(destinationID: PutioFileID?, to requests: PutioFolderRefreshRequests) {
    if let destinationID {
      requests.request(folderID: destinationID)
    } else {
      requests.requestAllLoadedFolders()
    }
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

struct PutioOfflineTrackPickerRequest: Identifiable {
  let route: PutioFileRoute
  let inventory: PutioOfflineInventory

  var id: PutioFileID { route.id }
}

enum PutioOfflineQueueFactory {
  @MainActor
  static func make(runtime: PutioRuntime, accountID: Int, scenario: HarnessScenario)
    -> PutioOfflineQueue
  {
    #if DEBUG
      let harness = scenario == .filesBrowser
    #else
      let harness = false
    #endif
    let engine: any PutioOfflineDownloadEngine = PutioSystemOfflineDownloadEngine(
      accountID: accountID)
    return PutioOfflineQueue(
      store: PutioOfflineStore(
        directory: harness
          ? FileManager.default.temporaryDirectory.appending(path: "harness-offline")
          : nil,
        accountID: accountID),
      engine: engine,
      conversionPollInterval: harness ? .milliseconds(1_200) : .seconds(3),
      notifyCompletion: { item in
        guard !harness else { return }
        PutioOfflineNotifications.notifyCompletion(item)
      },
      resolve: { fileID, kind in
        switch kind {
        case .audio:
          let source = try await runtime.resolveAudioPlaybackSource(fileID: fileID)
          return .ready(PutioOfflineQueueFactory.swap(source, scenario: scenario, kind: kind))
        case .video:
          let resolution = try await runtime.resolveVideoPlaybackSource(fileID: fileID)
          guard case .ready(let source) = resolution else { return resolution }
          return .ready(PutioOfflineQueueFactory.swap(source, scenario: scenario, kind: kind))
        }
      },
      startConversion: { fileID in try await runtime.startVideoConversion(fileID: fileID) },
      conversionStatus: { fileID in try await runtime.videoConversionStatus(fileID: fileID) },
      reportPosition: { fileID, seconds in
        try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
      }
    )
  }

  /// The seeded scenario pins preferred languages so the journey is
  /// independent of the simulator's locale.
  static func preferredLanguages(scenario: HarnessScenario) -> [String] {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if scenario == .filesBrowser,
        let index = arguments.firstIndex(of: "--putio-harness-preferred-languages"),
        arguments.indices.contains(index + 1)
      {
        return arguments[index + 1].split(separator: ",").map(String.init)
      }
    #endif
    return Locale.preferredLanguages
  }

  /// The seeded scenario downloads local fixtures instead of api.put.io streams.
  static func swap(
    _ source: PutioPlaybackSource, scenario: HarnessScenario, kind: PutioOfflineItem.Kind
  )
    -> PutioPlaybackSource
  {
    #if DEBUG
      guard scenario == .filesBrowser,
        let baseURLString = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let baseURL = URL(string: baseURLString), baseURL.scheme == "http",
        baseURL.host == "127.0.0.1"
      else { return source }
      let path = kind == .audio ? "runtime-proof-audio.m4a" : "multi-audio/runtime-proof-multi.m3u8"
      return PutioPlaybackSource(
        url: baseURL.appending(path: path), startFromSeconds: source.startFromSeconds)
    #else
      return source
    #endif
  }
}

enum PutioExternalPlaybackOpener {
  static func make(scenario: HarnessScenario) -> PutioExternalURLOpening {
    #if DEBUG
      if scenario == .filesBrowser {
        return HarnessExternalURLOpener(
          vlcInstalled: ProcessInfo.processInfo.arguments.contains(
            "--putio-harness-vlc-installed"))
      }
    #endif
    return PutioSystemURLOpener()
  }
}

#if DEBUG
  /// Records handoff requests for the journey instead of leaving the app. The
  /// tokened stream URL is reduced to its scheme, host, and path before it is
  /// exposed.
  final class HarnessExternalURLOpener: PutioExternalURLOpening, @unchecked Sendable {
    let vlcInstalled: Bool
    private static var requests: [String] = []
    private static let lock = NSLock()

    init(vlcInstalled: Bool) {
      self.vlcInstalled = vlcInstalled
    }

    static func summary() -> String {
      lock.withLock { "\(requests.count)|\(requests.last ?? "")" }
    }

    @MainActor func canOpen(_ url: URL) -> Bool {
      url.scheme == PutioVLCHandoff.scheme ? vlcInstalled : true
    }

    @MainActor func open(_ url: URL) async -> Bool {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var summary = "\(url.scheme ?? "")://\(components?.host ?? "")\(components?.path ?? "")"
      if let target = components?.queryItems?.first(where: { $0.name == "url" })?.value,
        let targetURL = URL(string: target)
      {
        summary += "?url=\(targetURL.scheme ?? "")://\(targetURL.host ?? "")\(targetURL.path)"
      }
      if let success = components?.queryItems?.first(where: { $0.name == "x-success" })?.value {
        summary += "&x-success=\(success)"
      }
      Self.lock.withLock { Self.requests.append(summary) }
      return true
    }
  }

  private struct HarnessRatingLinkCapture: ViewModifier {
    let enabled: Bool
    @State private var openedURLs: [URL] = []

    func body(content: Content) -> some View {
      if enabled {
        content
          .environment(
            \.openURL,
            OpenURLAction { url in
              openedURLs.append(url)
              return .handled
            }
          )
          .overlay {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement()
              .accessibilityLabel("External link requests")
              .accessibilityValue(
                "\(openedURLs.count)|\(openedURLs.last?.absoluteString ?? "")"
              )
              .accessibilityIdentifier("account.rating-link-requests")
              .allowsHitTesting(false)
          }
      } else {
        content
      }
    }
  }
#endif

enum PutioCastControllerFactory {
  static func usesGoogleCast(scenario: HarnessScenario) -> Bool {
    #if DEBUG
      scenario != .filesBrowser && scenario != .gallery && scenario != .exercised
    #else
      true
    #endif
  }

  @MainActor
  static func makeModel(runtime: PutioRuntime, scenario: HarnessScenario) -> PutioCastModel {
    let controller: any PutioCastControlling
    #if DEBUG
      let harness = scenario == .filesBrowser
      if !usesGoogleCast(scenario: scenario) {
        controller = PutioHarnessCastController(
          failLoadsBeforeSuccess: ProcessInfo.processInfo.arguments.contains(
            "--putio-harness-cast-load-fails-once") ? 1 : 0,
          hasReceiver: harness)
      } else {
        controller = PutioGoogleCastController()
      }
    #else
      let harness = false
      controller = PutioGoogleCastController()
    #endif
    return PutioCastModel(
      controller: controller,
      positionReportInterval: harness ? .seconds(3) : .seconds(15),
      conversionPollInterval: harness ? .milliseconds(1_200) : .seconds(3),
      resolve: { fileID, playbackType in
        try await runtime.resolveCastMedia(fileID: fileID, playbackType: playbackType)
      },
      loadPlaybackType: { try await runtime.castPlaybackType() },
      savePlaybackType: { try await runtime.setCastPlaybackType($0) },
      startConversion: { try await runtime.startVideoConversion(fileID: $0) },
      loadConversionStatus: { try await runtime.videoConversionStatus(fileID: $0) },
      reportPosition: { fileID, seconds in
        try await runtime.reportVideoPlaybackPosition(fileID: fileID, seconds: seconds)
      }
    )
  }
}

/// The Cast surfaces that ride on the tab shell: the bar above the tab bar,
/// the expanded controls sheet, and the harness stub picker.
struct PutioCastPresentation: ViewModifier {
  let model: PutioCastModel

  func body(content: Content) -> some View {
    content
      .modifier(PutioCastBarAccessory(model: model))
      .sheet(
        isPresented: Binding(
          get: { model.presentsControls }, set: { if !$0 { model.hideControls() } })
      ) {
        PutioCastControlsView(model: model)
          .preferredColorScheme(.dark)
      }
      .modifier(PutioHarnessCastPresentation(model: model))
  }
}

/// Presents the harness stub picker; a no-op outside the seeded scenario.
struct PutioHarnessCastPresentation: ViewModifier {
  let model: PutioCastModel

  func body(content: Content) -> some View {
    #if DEBUG
      if let controller = model.harnessController {
        content.sheet(
          isPresented: Binding(
            get: { controller.presentsPicker }, set: { if !$0 { controller.dismissPicker() } })
        ) {
          PutioHarnessCastPicker(controller: controller)
            .preferredColorScheme(.dark)
        }
      } else {
        content
      }
    #else
      content
    #endif
  }
}

/// The accessory slot reserves its height whenever it is installed, so the
/// bar is installed only while a receiver has something of ours.
private struct PutioCastBarAccessory: ViewModifier {
  let model: PutioCastModel

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: model.hasSession) {
        PutioCastBar(model: model)
      }
    } else if model.hasSession {
      content.tabViewBottomAccessory { PutioCastBar(model: model) }
    } else {
      content
    }
  }
}
