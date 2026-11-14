import AVFoundation
import PutioCore
import SwiftUI

// The iOS 26 shell: a stock TabView whose floating glass
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
    _pins = State(
      initialValue: PutioPinnedFilesModel(
        actions: PutioPinnedFilesActions(runtime: runtime), rootName: PutioFolderRoute.root.title))
    #if DEBUG
      HarnessContinueWatching.seed(scenario: scenario, accountID: account.id)
    #endif
    _continueWatching = State(
      initialValue: PutioContinueWatchingModel(
        store: PutioContinueWatchingStore(accountID: account.id)))
  }

  private enum SelectedTab: Hashable {
    case files, downloads, history, account, search
    case pin(PutioFileID)
  }
  @State private var selectedTab: SelectedTab = .files
  @State private var filesNavigation: PutioFilesNavigationRequest?
  @State private var accountNavigationRevision: UInt64 = 0
  @State private var showsLinkDevice = false
  @State private var linkDeviceCode: String?
  @State private var selectedFileRoute: PutioFileRoute?
  @State private var selectedVideoRoute: PutioVideoRoute?
  @State private var harnessPlaybackAttempt = 0
  @State private var harnessReportedPosition: (fileID: PutioFileID, seconds: Int)?
  @State private var harnessAudioSaves: [(fileID: PutioFileID, seconds: Int)] = []
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var folderRefreshRequests: PutioFolderRefreshRequests
  @State private var trashReconciliation = PutioTrashReconciliation()
  @State private var historyRevision: UInt64 = 0
  @State private var presentedVideoRoute: PutioVideoRoute?
  @State private var resumePrompter = PutioVideoResumePrompter()
  @State private var videoStartTask: Task<Void, Never>?
  @State private var audioPlayback = PutioAudioPlaybackSession()
  @State private var miniPlayerPlacement = PutioAudioMiniPlayerPlacement()
  @State private var presentedPreview: PutioPreviewPresentation?
  @State private var previewToast: PutioToast?
  #if DEBUG
    @State private var harnessPreviewRequests = HarnessPreviewRequests()
  #endif
  @State private var externalPlayback: PutioExternalPlaybackModel
  @State private var offlineQueueHolder: PutioOfflineQueueHolder
  private var offlineQueue: PutioOfflineQueue { offlineQueueHolder.queue }
  @State private var appConfig: PutioAppConfigModel
  @State private var pins: PutioPinnedFilesModel
  @State private var continueWatching: PutioContinueWatchingModel
  @State private var analyticsPrompt: PutioProductAnalyticsPromptModel?
  @State private var trackPicker: PutioOfflineTrackPickerRequest?
  @State private var offlineFailure: PutioOfflineFailure?
  @Environment(\.scenePhase) private var scenePhase

  private var miniPlayer: PutioAudioMiniPlayerSlot {
    PutioAudioMiniPlayerSlot(
      playback: audioPlayback, placement: miniPlayerPlacement, onStop: { stopAudio() })
  }

  private var shellToast: Binding<PutioToast?> {
    presentedPreview == nil ? $previewToast : .constant(nil)
  }

  var body: some View {
    if #available(iOS 27.1, *) {
      PutioRailEdgeReader { shell(railed: $0 != nil) }
    } else {
      shell(railed: false)
    }
  }

  private func shell(railed: Bool) -> some View {
    let tabBarVisibility: Visibility = railed && presentedPreview != nil ? .hidden : .automatic
    return TabView(selection: tabSelection) {
      Tab(value: SelectedTab.files) {
        filesBrowser
          .shellTabContent(shellToast, tabBar: tabBarVisibility, miniPlayer: miniPlayer)
      } label: {
        Label {
          Text("Files")
        } icon: {
          tabIcon(.folderFill, for: .files)
        }
      }
      Tab(value: SelectedTab.downloads) {
        downloads
          .shellTabContent(shellToast, tabBar: tabBarVisibility, miniPlayer: miniPlayer)
      } label: {
        Label {
          Text("Downloads")
        } icon: {
          tabIcon(.arrowCircleDown, for: .downloads)
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
          .shellTabContent(shellToast, tabBar: tabBarVisibility, miniPlayer: miniPlayer)
          .id(historyRevision)
        } label: {
          Label {
            Text("History")
          } icon: {
            tabIcon(.clockCounterClockwise, for: .history)
          }
        }
      }
      Tab(value: SelectedTab.account) {
        AccountScreen(
          runtime: runtime,
          account: account,
          refreshRequests: folderRefreshRequests,
          trashReconciliation: trashReconciliation,
          cast: cast,
          appConfig: appConfig,
          showsLinkDevice: $showsLinkDevice,
          linkDeviceCode: linkDeviceCode,
          downloads: offlineQueue,
          onDataCleared: { categories, committed in
            if !categories.isDisjoint(with: [.files, .trash]) {
              folderRefreshRequests.requestAllLoadedFolders()
            }
            if categories.contains(.history) { historyRevision &+= 1 }
            // Downloaded copies of cleared files would only play as orphans.
            if committed, categories.contains(.files) { offlineQueue.purgeAccountStorage() }
          }
        )
        .shellTabContent(shellToast, tabBar: tabBarVisibility, miniPlayer: miniPlayer)
        .id(accountNavigationRevision)
      } label: {
        Label {
          Text("Account")
        } icon: {
          tabIcon(.userCircle, for: .account)
        }
      }
      Tab(value: SelectedTab.search, role: .search) {
        FilesSearchView(
          runtime: runtime,
          trashEnabled: account.trashEnabled,
          tracksWatched: account.rememberVideoTime,
          refreshRequests: folderRefreshRequests,
          pins: pins,
          onFileSelected: { route in selectFile(route) },
          onExternalPlayback: vlcAction,
          onDownload: { route in Task { await requestDownload(route) } }
        )
        .putioToast($externalPlayback.toast)
        .environment(\.putioFileShare, fileShare)
        .shellTabContent(shellToast, tabBar: tabBarVisibility, miniPlayer: miniPlayer)
      } label: {
        Label {
          Text("Search")
        } icon: {
          tabIcon(systemName: "magnifyingglass", for: .search)
        }
      }
      if !pins.sectionItems.isEmpty {
        TabSection {
          ForEach(pins.sectionItems) { pin in
            Tab(value: SelectedTab.pin(pin.id)) {
              EmptyView()
            } label: {
              Label {
                Text(pin.item.name)
              } icon: {
                Image(
                  putioIcon: PutioBrowserItemPresentation.rowKind(for: pin.item.kind).icon)
              }
            }
            .defaultVisibility(.hidden, for: .tabBar)
            .accessibilityIdentifier("shell.pinned.item.\(pin.id.rawValue)")
          }
        } header: {
          Text("Pinned")
        }
      }
    }
    .tint(PutioTheme.Colors.accent)
    .tabViewStyle(.sidebarAdaptable)
    .defaultAdaptableTabBarPlacement(.tabBar)
    .tabViewSidebarBottomBar {
      PutioStorageMeter(storage: account.storage)
    }
    .environment(\.putioDefaultFolderSort, account.defaultSort)
    // Shrink-on-scroll is opt-in on iOS 26.
    .tabBarMinimizeBehavior(.onScrollDown)
    .tabViewSearchActivation(.searchTabSelection)
    .task {
      externalPlayback.refreshInstallation()
      await appConfig.loadIfNeeded()
      askProductAnalyticsIfNeeded()
    }
    .modifier(PutioCastPresentation(model: cast, audio: miniPlayer))
    .putioVideoResumeAlert(resumePrompter)
    .accessibilityHidden(selectedVideoRoute != nil)
    .overlay {
      if let preview = presentedPreview {
        PutioPreviewView(
          route: preview.route,
          file: preview.file,
          source: preview.source,
          fileActions: PutioPreviewFileActions(
            runtime: runtime, trashEnabled: account.trashEnabled,
            refreshRequests: folderRefreshRequests),
          download: { preview, extent in try await downloadPreview(preview, extent) },
          toast: $previewToast,
          onDismiss: {
            guard presentedPreview?.id == preview.id else { return }
            presentedPreview = nil
          }
        )
        .id(preview.id)
        .accessibilityAddTraits(.isModal)
      }
    }
    .overlay {
      PutioSelectedVideoCover(route: $selectedVideoRoute) { route in
        videoPlayer(for: route)
      }
    }
    // Keyed on the cover, not the route, so the next video keeps the lock.
    .onChange(of: selectedVideoRoute != nil && appConfig.autoRotateVideo, initial: true) {
      _, locked in PutioVideoOrientationLock.setLocked(locked)
    }
    // A link that arrives after the ask still wins; a save in flight finishes
    // on its own, and an unanswered prompt asks again next launch.
    .onChange(of: deepLinks.hasReceivedLink) { _, received in
      if received { analyticsPrompt = nil }
    }
    .onChange(of: account.productAnalyticsEnabled) { _, enabled in
      if enabled, analyticsPrompt?.isSaving == false { analyticsPrompt = nil }
    }
    .sheet(
      isPresented: Binding(
        get: { analyticsPrompt != nil }, set: { if !$0 { analyticsPrompt = nil } })
    ) {
      if let analyticsPrompt {
        ProductAnalyticsPromptView(model: analyticsPrompt)
          .preferredColorScheme(.dark)
      }
    }
    .sheet(isPresented: $audioPlayback.isPresented) {
      if let model = audioPlayback.model {
        PutioAudioPlayerView(
          model: model,
          castButton: playerCastButton,
          onDismiss: { audioPlayback.isPresented = false },
          showsHarnessReadiness: scenario == .filesBrowser)
      }
    }
    .onDisappear {
      stopAudio()
      offlineQueueHolder.stop()
      PutioVideoOrientationLock.setLocked(false)
    }
    .onChange(of: cast.hasSession) { _, hasSession in
      if hasSession { stopAudio() }
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
    .putioAlert(
      String(localized: "Could not start download"),
      isPresented: Binding(
        get: { offlineFailure != nil }, set: { if !$0 { offlineFailure = nil } }),
      message: offlineFailure?.message,
      actions: [PutioAlertAction(String(localized: "OK"), tier: .neutral)]
    )
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      externalPlayback.refreshInstallation()
      Task { await offlineQueue.syncPendingPositions() }
      Task { await runtime.refreshAccount() }
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
      presentedPreview = nil
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

  /// Once per signed-in shell. A config that failed to load asks nothing;
  /// the next launch reads it again. The account is read from the session,
  /// since a setting changed while the config loaded postdates `account`,
  /// and a preferences write still in flight leaves the answer to it.
  private func askProductAnalyticsIfNeeded() {
    guard HarnessLaunch.allowsProductAnalyticsPrompt, let config = appConfig.config,
      !runtime.session.isUpdatingAccountPreferences,
      case .signedIn(let current) = runtime.session.state, current.id == account.id,
      PutioProductAnalyticsPrompt.shouldAsk(
        productAnalyticsEnabled: current.productAnalyticsEnabled,
        promptAnswered: config.productAnalyticsPromptAnswered,
        opensLaunchLink: deepLinks.hasReceivedLink)
    else { return }
    analyticsPrompt = PutioProductAnalyticsPromptModel(actions: .init(runtime: runtime))
  }

  private func tabIcon(_ icon: PutioIcon, for tab: SelectedTab) -> Image {
    selectedTab == tab
      ? Image(putioIcon: icon) : Image(putioIcon: icon, fixed: PutioTheme.Colors.textPrimary)
  }

  private func tabIcon(systemName: String, for tab: SelectedTab) -> Image {
    selectedTab == tab
      ? Image(systemName: systemName)
      : Image(systemName: systemName, fixed: PutioTheme.Colors.textPrimary)
  }

  private var tabSelection: Binding<SelectedTab> {
    Binding(
      get: { selectedTab },
      set: { tab in
        guard case .pin(let id) = tab else {
          selectedTab = tab
          return
        }
        if let pin = pins.sectionItems.first(where: { $0.id == id }) { openPin(pin) }
      })
  }

  private func openPin(_ pin: PutioPinnedFile) {
    let item = pin.item
    selectedTab = .files
    if item.kind == .folder {
      filesNavigation = PutioFilesNavigationRequest(
        path: [PutioFolderRoute(id: item.id, title: item.name)])
      return
    }
    if item.parentID == .root {
      filesNavigation = PutioFilesNavigationRequest(path: [])
    } else if let location = pin.location {
      filesNavigation = PutioFilesNavigationRequest(
        path: [PutioFolderRoute(id: item.parentID, title: location)])
    }
    selectFile(PutioFileRoute(item: item))
  }

  private func selectFile(_ route: PutioFileRoute, in source: PutioPreviewSource? = nil) {
    cancelVideoStart()
    selectedFileRoute = route
    switch route.openAction {
    case .video(let videoRoute):
      playVideo(videoRoute)
    case .audio(let audioRoute):
      presentAudio(audioRoute)
    case .preview, .unsupported:
      presentedPreview = PutioViewerRoute(opening: route.openAction).map {
        PutioPreviewPresentation(route: $0, file: route, source: source)
      }
    }
  }

  private func reconcileContinueWatching() async {
    await continueWatching.reconcile(
      loadFile: { try await runtime.getFile(fileID: $0) },
      keepsLocalPosition: { offlineQueue.item(for: $0)?.isPlayable == true })
  }

  private func resumeVideo(_ route: PutioVideoRoute) {
    if let item = offlineQueue.item(for: route.id), item.isPlayable {
      openOffline(item)
    } else {
      playVideo(route)
    }
  }

  private func playVideo(_ route: PutioVideoRoute) {
    stopAudio()
    if cast.isConnected, offlineQueue.item(for: route.id)?.isPlayable != true {
      cast.cast(route)
    } else {
      presentVideo(route)
    }
  }

  private func requestDownloads(_ routes: [PutioFileRoute]) async {
    for route in routes {
      await requestDownload(route, picksLanguages: false)
    }
  }

  /// Multi-audio videos go through the picker unless `picksLanguages` is off,
  /// which keeps every language; everything else queues directly.
  private func requestDownload(_ route: PutioFileRoute, picksLanguages: Bool = true) async {
    let kind: PutioOfflineItem.Kind = route.item.kind == .audio ? .audio : .video
    offlineQueue.refreshStorage()
    var estimate: Int64 = route.item.sizeBytes
    var awaitsLanguages = false
    var audioLanguages: [String] = []
    do {
      switch try await offlineQueue.inventory(fileID: route.id, kind: kind) {
      case .ready(let inventory):
        let languages = inventory.audioOptions.map(\.languageCode)
        if languages.count > 1 {
          guard !picksLanguages else {
            trackPicker = PutioOfflineTrackPickerRequest(route: route, inventory: inventory)
            return
          }
          audioLanguages = languages
        }
        estimate = inventory.estimatedBytes(selecting: languages)
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
          kind: .resolution,
          message: String(localized: "The file could not be inspected. Try again."))
      return
    }
    enqueueDownload(
      route, audioLanguages: audioLanguages, estimatedBytes: estimate,
      awaitsLanguageSelection: awaitsLanguages)
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

  /// Image and PDF previews download the whole file and text previews only its
  /// start; the tokened URL never leaves this call.
  /// A rejected token on the raw GET is re-checked through the runtime, which
  /// signs the account out when the session really expired.
  private func downloadPreview(_ route: PutioPreviewRoute, _ extent: PutioPreviewExtent)
    async throws -> Data
  {
    #if DEBUG
      guard scenario == .filesBrowser else { return try await fetchPreview(route, extent) }
      do {
        let data = try await fetchPreview(route, extent)
        harnessPreviewRequests.record(route.id, extent == .whole ? .shared : .loaded)
        return data
      } catch {
        harnessPreviewRequests.record(route.id, Task.isCancelled ? .cancelled : .failed)
        throw error
      }
    #else
      return try await fetchPreview(route, extent)
    #endif
  }

  private func fetchPreview(_ route: PutioPreviewRoute, _ extent: PutioPreviewExtent)
    async throws -> Data
  {
    let source = try await runtime.resolveFileDownloadSource(fileID: route.id)
    let url = try harnessPreviewURL(for: source) ?? source.url
    do {
      switch (route.kind, extent) {
      case (.image, _), (.pdf, _), (.text, .whole):
        return try await PutioPreviewDownloader.download(url)
      case (.text, .preview):
        return try await PutioPreviewDownloader.downloadPrefix(
          url, byteCount: PutioPreviewRoute.textLimitBytes + 1)
      }
    } catch PutioRuntimeError.sessionExpired {
      _ = try await runtime.getFile(fileID: route.id)
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
      case .pdf where source.id.rawValue == HarnessSeededAPI.corruptDocumentFileID:
        return baseURL.appending(path: "runtime-proof-image.png")
      case .pdf: return baseURL.appending(path: "runtime-proof-document.pdf")
      case .text where source.id.rawValue == HarnessSeededAPI.longTextFileID:
        return baseURL.appending(path: "runtime-proof-long.srt")
      case .text where source.id.rawValue == HarnessSeededAPI.binaryTextFileID:
        return baseURL.appending(path: "runtime-proof-image.png")
      case .text: return baseURL.appending(path: "runtime-proof-subtitles.srt")
      default: return nil
      }
    #else
      return nil
    #endif
  }

  private func presentAudio(_ route: PutioAudioRoute) {
    cancelVideoStart()
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
          #if DEBUG
            if scenario == .filesBrowser {
              harnessAudioSaves.append((fileID, seconds))
            }
          #endif
        },
        resolve: { fileID in
          if let local = offlineQueue.localSource(for: fileID) { return local }
          return try await resolveAudioSource(fileID: fileID)
        },
        loadNeighbours: { track in
          do {
            return try await runtime.audioNeighbours(of: track.id, in: track.parentID)
          } catch PutioRuntimeError.transient {
            let files = PutioOfflineFolderFiles(queue: offlineQueue, open: openOffline)
              .items(track.parentID)
            guard let stored = PutioAudioNeighbours.stored(files, around: track) else {
              throw PutioRuntimeError.transient
            }
            return stored
          }
        }
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
    videoStartTask?.cancel()
    videoStartTask = Task { await openVideo(route) }
    // The autoplay decision reads the document at playback end; a load that
    // failed at sign-in gets another chance before this video finishes.
    Task { await appConfig.loadIfNeeded() }
  }

  private func openVideo(_ route: PutioVideoRoute) async {
    guard account.rememberVideoTime else {
      showVideo(route)
      return
    }
    await playbackPositionPipeline.waitForPendingReports(fileID: route.id)
    let start = await videoStartPoint(for: route)
    guard !Task.isCancelled else { return }
    if route.initialResolution == nil, cast.isConnected {
      cast.cast(route)
      return
    }
    guard let start, !start.needsConversion,
      PutioVideoStart.asksWhereToStart(
        savedSeconds: start.savedSeconds, durationSeconds: start.durationSeconds,
        remembersPosition: account.rememberVideoTime)
    else {
      showVideo(route)
      return
    }
    guard let choice = await resumePrompter.ask(positionSeconds: start.savedSeconds),
      !Task.isCancelled
    else { return }
    showVideo(route.starting(with: choice))
  }

  private func videoStartPoint(for route: PutioVideoRoute) async -> PutioVideoStartPoint? {
    if case .ready(let source) = route.initialResolution {
      guard source.startFromSeconds > 0 else { return nil }
      return PutioVideoStartPoint(
        savedSeconds: source.startFromSeconds,
        durationSeconds: await PutioVideoLength.seconds(of: source.url), needsConversion: false)
    }
    return try? await runtime.videoStartPoint(fileID: route.id)
  }

  private func showVideo(_ route: PutioVideoRoute) {
    selectedVideoRoute = route
    presentedVideoRoute = route
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
      pins: pins,
      tracksWatched: account.rememberVideoTime,
      onFileSelected: { route in selectFile(route) },
      onExternalPlayback: vlcAction,
      onDownload: { route in Task { await requestDownload(route) } },
      onBulkDownload: { routes in Task { await requestDownloads(routes) } },
      refreshRequests: folderRefreshRequests,
      navigationRequest: filesNavigation,
      castButton: { AnyView(PutioCastButton(model: cast)) },
      accountNotice: PutioInactiveAccountNotice(account: account),
      offlineFiles: PutioOfflineFolderFiles(queue: offlineQueue, open: openOffline)
    )
    .putioToast($externalPlayback.toast)
    .environment(
      \.putioContinueWatching,
      PutioContinueWatchingContext(
        model: continueWatching, play: { resumeVideo($0) },
        reconcile: { await reconcileContinueWatching() })
    )
    .environment(\.putioAccountStorage, account.storage)
    .task(id: folderRefreshRequests.revision) {
      await reconcileContinueWatching()
    }
    .environment(
      \.putioPreviewOpen,
      PutioPreviewOpenAction { route, source in selectFile(route, in: source) }
    )
    .environment(\.putioFileShare, fileShare)
  }

  private var fileShare: PutioFileShareAction {
    PutioFileShareAction(
      localFile: { offlineQueue.localSource(for: $0)?.url },
      fetch: { route, extent in try await downloadPreview(route, extent) })
  }

  private func videoPlayer(for route: PutioVideoRoute) -> some View {
    PutioVideoPlaybackView(
      route: route,
      onDismiss: dismissPresentedVideo,
      onDurationKnown: { duration in
        continueWatching.opened(
          fileID: route.id, parentID: route.parentID, name: route.title,
          durationSeconds: duration)
      },
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
        continueWatching.positionSaved(fileID: fileID, seconds: seconds)
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
        HarnessAudioSavesProbe(saves: harnessAudioSaves)
        HarnessExternalPlaybackProbe(requestCount: externalPlayback.openedRequestCount)
        HarnessPreviewRequestsProbe(requests: harnessPreviewRequests)
        HarnessPasteboardProbe()
        HarnessSearchRequestsProbe()
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

  private var vlcAction: PutioFileSelection? {
    guard externalPlayback.isVLCInstalled else { return nil }
    return { route in Task { await externalPlayback.open(route) } }
  }

  private func cancelVideoStart() {
    videoStartTask?.cancel()
    videoStartTask = nil
    resumePrompter.answer(nil)
  }

  private func dismissPresentedVideo() {
    cancelVideoStart()
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

  /// Stops only a queue that was built; teardown must not build one.
  func stop() { built?.stop() }
}

extension View {
  fileprivate func shellTabContent(
    _ toast: Binding<PutioToast?>, tabBar: Visibility, miniPlayer: PutioAudioMiniPlayerSlot
  ) -> some View {
    putioToast(toast)
      .tint(PutioTheme.Colors.textPrimary)
      .toolbarVisibility(tabBar, for: .tabBar)
      .modifier(PutioAudioMiniPlayerInset(slot: miniPlayer))
  }
}
