import AVFoundation
import PutioCore
import SwiftUI

// The iOS 26 shell (ios-s00, ios-e10): a stock TabView whose floating glass
// capsule, shrink-on-scroll, and separate Search capsule are all owned by the
// OS. put.io supplies the tint on the selected tab and the Phosphor glyphs.
struct MainTabView: View {
  let runtime: PutioRuntime
  let cast: PutioCastModel
  let account: PutioAccountSnapshot
  let deepLinks: PutioDeepLinkModel
  let scenario: HarnessScenario
  let autoSignOutAfterSeconds: TimeInterval?

  init(
    runtime: PutioRuntime,
    cast: PutioCastModel,
    account: PutioAccountSnapshot,
    deepLinks: PutioDeepLinkModel,
    scenario: HarnessScenario,
    autoSignOutAfterSeconds: TimeInterval?
  ) {
    self.runtime = runtime
    self.cast = cast
    self.account = account
    self.deepLinks = deepLinks
    self.scenario = scenario
    self.autoSignOutAfterSeconds = autoSignOutAfterSeconds
    _externalPlayback = State(
      initialValue: PutioExternalPlaybackModel(
        opener: PutioExternalPlaybackOpener.make(scenario: scenario),
        resolve: { fileID in try await runtime.resolveFileDownloadSource(fileID: fileID) }
      ))
    let folderRefreshRequests = PutioFolderRefreshRequests()
    _folderRefreshRequests = State(initialValue: folderRefreshRequests)
    _offlineQueueHolder = State(
      initialValue: PutioOfflineQueueHolder {
        PutioOfflineQueueFactory.make(
          runtime: runtime, accountID: account.id, scenario: scenario,
          onOriginalsRequested: { folderRefreshRequests.requestAllLoadedFolders() })
      })
    _appConfig = State(initialValue: PutioAppConfigModel(actions: .init(runtime: runtime)))
  }

  private enum SelectedTab: Hashable { case files, downloads, history, account, search }
  @State private var selectedTab: SelectedTab = .files
  @State private var filesNavigation: PutioFilesNavigationRequest?
  @State private var accountNavigationRevision: UInt64 = 0
  @State private var showsLinkDevice = false
  @State private var linkDeviceCode: String?
  @State private var selectedFileRoute: PutioFileRoute?
  @State private var selectedVideoRoute: PutioVideoRoute?
  @State private var harnessPlaybackAttempt = 0
  @State private var harnessReportedPosition: (fileID: PutioFileID, seconds: Int)?
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var folderRefreshRequests: PutioFolderRefreshRequests
  @State private var trashReconciliation = PutioTrashReconciliation()
  @State private var historyRevision: UInt64 = 0
  @State private var presentedVideoRoute: PutioVideoRoute?
  @State private var audioPlayback = PutioAudioPlaybackSession()
  @State private var presentedPreviewRoute: PutioPreviewRoute?
  @State private var presentedUnsupportedRoute: PutioUnsupportedFileRoute?
  @State private var externalPlayback: PutioExternalPlaybackModel
  @State private var offlineQueueHolder: PutioOfflineQueueHolder
  private var offlineQueue: PutioOfflineQueue { offlineQueueHolder.queue }
  @State private var appConfig: PutioAppConfigModel
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
        downloads
      } label: {
        Label {
          Text("Downloads")
        } icon: {
          Image(putioIcon: .arrowCircleDown)
        }
      }
      // Stays while a write is unsaved, in case its alert could not present.
      .badge(offlineQueue.persistenceFailure == nil ? nil : Text("!"))
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
            appConfig: appConfig,
            showsLinkDevice: $showsLinkDevice,
            linkDeviceCode: linkDeviceCode,
            onDataCleared: { categories, committed in
              if !categories.isDisjoint(with: [.files, .trash]) {
                folderRefreshRequests.requestAllLoadedFolders()
              }
              if categories.contains(.history) { historyRevision &+= 1 }
              // Downloaded copies of cleared files would only play as orphans.
              if committed, categories.contains(.files) { offlineQueue.purgeAccountStorage() }
            },
            onAccountDestroyed: {
              // Nothing account-scoped may outlive an account that can never
              // sign in again: local media and the saved Files location.
              offlineQueue.purgeAccountStorage()
              PutioFilesNavigationRestoration().clear(accountID: account.id)
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
    .environment(\.putioDefaultFolderSort, account.defaultSort)
    // Shrink-on-scroll is opt-in on iOS 26 and part of the ios-e10 treatment.
    .tabBarMinimizeBehavior(.onScrollDown)
    .task { await appConfig.loadIfNeeded() }
    .modifier(PutioCastPresentation(model: cast, audioPlayback: audioPlayback))
    .accessibilityHidden(selectedVideoRoute != nil)
    .overlay {
      PutioSelectedVideoCover(route: $selectedVideoRoute) { route in
        videoPlayer(for: route)
      }
    }
    .sheet(isPresented: $audioPlayback.isPresented) {
      if let model = audioPlayback.model {
        PutioAudioPlayerView(
          model: model,
          onDismiss: { audioPlayback.isPresented = false },
          showsHarnessReadiness: scenario == .filesBrowser)
      }
    }
    .onDisappear { stopAudio() }
    .onChange(of: cast.hasSession) { _, hasSession in
      if hasSession { stopAudio() }
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
    .modifier(PutioOfflinePersistenceFailureAlert(queue: offlineQueue))
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
    .modifier(PutioExternalPlaybackPresentation(model: externalPlayback))
    .overlay(alignment: .topLeading) {
      #if DEBUG
        if scenario == .filesBrowser, let selectedFileRoute {
          HarnessFileSelectionProbe(route: selectedFileRoute)
        }
      #endif
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
      audioPlayback.isPresented = false
      presentedPreviewRoute = nil
      presentedUnsupportedRoute = nil
      trackPicker = nil
      switch destination {
      case .files(let path, let file):
        filesNavigation = PutioFilesNavigationRequest(path: path)
        selectedTab = .files
        if let file { selectFile(file) }
      case .downloads(let id):
        selectedTab = .downloads
        if let item = PutioDeepLinkDestination.playableDownload(id, in: offlineQueue.item(for:)) {
          openOffline(item)
        }
      case .history:
        historyRevision &+= 1
        selectedTab = .history
      case .account:
        accountNavigationRevision &+= 1
        showsLinkDevice = false
        linkDeviceCode = nil
        selectedTab = .account
      case .linkDevice(let code):
        accountNavigationRevision &+= 1
        showsLinkDevice = true
        linkDeviceCode = code
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
      stopAudio()
      if cast.isConnected, offlineQueue.item(for: route.id)?.isPlayable != true {
        cast.cast(videoRoute)
      } else {
        presentVideo(videoRoute)
      }
    case .audio(let audioRoute):
      presentAudio(audioRoute)
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
      presentAudio(PutioAudioRoute(id: item.id, parentID: item.parentID, title: item.name))
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

  private func presentAudio(_ route: PutioAudioRoute) {
    if cast.hasSession { cast.stopCasting() }
    if audioPlayback.model?.track.id == route.id {
      audioPlayback.isPresented = true
      return
    }
    stopAudio()
    audioPlayback.present(
      PutioAudioPlayerModel(
        track: PutioAudioTrack(id: route.id, parentID: route.parentID, title: route.title),
        engine: PutioSystemAudioEngine(),
        nowPlaying: PutioSystemNowPlayingSurface(),
        audioSession: PutioSystemAudioSession(),
        speedStore: PutioAudioSpeedStore(),
        positionPipeline: playbackPositionPipeline,
        remembersPlaybackPosition: { runtime.remembersPlaybackPosition },
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
      ))
  }

  private func stopAudio() {
    guard let track = audioPlayback.model?.track else { return }
    audioPlayback.stop()
    Task { @MainActor in
      await Task.yield()
      await playbackPositionPipeline.waitForPendingReports(fileID: track.id)
      folderRefreshRequests.request(folderID: track.parentID)
    }
  }

  private func presentVideo(_ route: PutioVideoRoute) {
    stopAudio()
    selectedVideoRoute = route
    presentedVideoRoute = route
    // The autoplay decision reads the document at playback end; a load that
    // failed at sign-in gets another chance before this video finishes.
    Task { await appConfig.loadIfNeeded() }
  }

  private var downloads: some View {
    NavigationStack {
      PutioOfflineDownloadsView(
        queue: offlineQueue, trashEnabled: account.trashEnabled,
        canDeleteOriginals: !runtime.session.isAccountPreferencesStale
          && !runtime.session.isUpdatingAccountPreferences,
        onOpen: { item in openOffline(item) })
    }
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
      autoplayNextVideo: { await appConfig.resolveAutoplayNextVideo() },
      showsHarnessReadiness: scenario == .filesBrowser,
      conversionPollInterval: scenario == .filesBrowser ? .milliseconds(1_200) : .seconds(3),
      nextVideoAutoplayDelay: .seconds(5),
      positionPipeline: playbackPositionPipeline,
      reportPosition: { fileID, seconds in
        if offlineQueue.item(for: fileID)?.isPlayable == true {
          await offlineQueue.recordPosition(fileID: fileID, seconds: seconds)
        } else {
          try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
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
          findOfflineNext: { offlineQueue.nextVideo(after: $0) },
          waitForPendingReports: {
            await playbackPositionPipeline.waitForPendingReports(fileID: $0)
          },
          resolve: { fileID in
            try await resolveSuccessorSource(
              fileID: fileID,
              localSource: { offlineQueue.localSource(for: $0) },
              resolve: { try await resolvePlaybackSource(fileID: $0) }
            )
          }
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
      let subtitledPath = HarnessSubtitledStream.path(for: account)
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
        fixtureURL = baseURL.appending(path: subtitledPath ?? "runtime-proof.m3u8")
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
          // Seeded positions exceed the 20-second subtitled fixture.
          startFromSeconds: subtitledPath == nil ? source.startFromSeconds : 0
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

struct PutioOfflineTrackPickerRequest: Identifiable {
  let route: PutioFileRoute
  let inventory: PutioOfflineInventory

  var id: PutioFileID { route.id }
}

/// SwiftUI runs `MainTabView.init` on every session update but keeps only the
/// first `State`, so the queue, which reads and writes its documents, is built
/// once on first use instead of on every init.
@MainActor
private final class PutioOfflineQueueHolder {
  private let make: @MainActor () -> PutioOfflineQueue
  private var built: PutioOfflineQueue?

  init(_ make: @escaping @MainActor () -> PutioOfflineQueue) { self.make = make }

  var queue: PutioOfflineQueue {
    if let built { return built }
    let queue = make()
    built = queue
    return queue
  }
}
