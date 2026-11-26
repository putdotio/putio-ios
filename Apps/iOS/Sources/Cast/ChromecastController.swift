import Foundation
import GoogleCast
import PutioCore
import SwiftUI
import UIKit

/// The Google Cast SDK behind `PutioCastControlling`. The shared context is
/// configured once per process with the effective receiver ID; discovery is
/// scoped to that receiver and starts when a player opens, so the
/// local-network prompt appears with intent, not at launch.
@MainActor
final class PutioGoogleCastController: NSObject, PutioCastControlling {
  private(set) var connection: PutioCastConnection = .unavailable
  private(set) var discovery = PutioCastDiscovery()
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onDiscoveryChanged: ((PutioCastDiscovery) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?

  private let localNetwork = PutioLocalNetworkProbe()
  private var pendingDeviceID: PutioCastDevice.ID?
  private var localNetworkDenied = false

  private var loadedFileID: PutioFileID?
  private static let putioReceiverAppID = PutioCastReceiver.putioAppID()
  private var castStateObservation: NSObjectProtocol?
  private var pendingRequests: [Int: CheckedContinuation<Void, Error>] = [:]
  private var pendingRequestObjects: [Int: GCKRequest] = [:]

  static func configureSharedContext(receiverAppID: String) {
    guard !GCKCastContext.isSharedInstanceInitialized() else { return }
    let criteria = GCKDiscoveryCriteria(applicationID: receiverAppID)
    let options = GCKCastOptions(discoveryCriteria: criteria)
    options.disableAnalyticsLogging = true
    options.startDiscoveryAfterFirstTapOnCastButton = true
    options.suspendSessionsWhenBackgrounded = false
    options.physicalVolumeButtonsWillControlDeviceVolume = true
    GCKCastContext.setSharedInstanceWith(options)
    GCKLogger.sharedInstance().filter = {
      let filter = GCKLoggerFilter()
      filter.minimumLevel = .error
      return filter
    }()
    applyStyle()
  }

  /// Cast chrome takes put.io tokens once; the app is dark-only so a single
  /// pass suffices. The expanded controller renders over artwork and keeps
  /// fixed over-media colors.
  private static func applyStyle() {
    let style = GCKUIStyle.sharedInstance()
    let views = style.castViews
    views.backgroundColor = UIColor(PutioTheme.Colors.background)
    views.headingTextColor = UIColor(PutioTheme.Colors.textPrimary)
    views.bodyTextColor = UIColor(PutioTheme.Colors.textPrimary)
    views.captionTextColor = UIColor(PutioTheme.Colors.textSecondary)
    views.buttonTextColor = UIColor(PutioTheme.Colors.accent)
    views.iconTintColor = UIColor(PutioTheme.Colors.textPrimary)
    views.sliderProgressColor = UIColor(PutioTheme.Colors.accent)
    views.sliderSecondaryProgressColor = UIColor(PutioTheme.Colors.surface)
    views.sliderUnseekableProgressColor = UIColor(PutioTheme.Colors.textSecondary)
    views.mediaControl.backgroundColor = UIColor(PutioTheme.Colors.surface)
    views.mediaControl.iconTintColor = UIColor(PutioTheme.Colors.accent)
    let expanded = views.mediaControl.expandedController
    expanded.backgroundColor = .black
    expanded.headingTextColor = .white
    expanded.bodyTextColor = .white
    expanded.captionTextColor = .lightGray
    expanded.iconTintColor = .white
    style.apply()
  }

  override init() {
    super.init()
    let context = GCKCastContext.sharedInstance()
    context.sessionManager.add(self)
    context.discoveryManager.add(self)
    castStateObservation = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.gckCastStateDidChange, object: context, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.castStateChanged() }
    }
    if let client = context.sessionManager.currentCastSession?.remoteMediaClient {
      client.add(self)
    }
    castStateChanged()
    discoveryChanged()
  }

  // The Cast SDK is main-thread only, so teardown stays on the main actor.
  isolated deinit {
    GCKCastContext.sharedInstance().discoveryManager.remove(self)
    let sessionManager = GCKCastContext.sharedInstance().sessionManager
    sessionManager.remove(self)
    sessionManager.currentCastSession?.remoteMediaClient?.remove(self)
    if let castStateObservation {
      NotificationCenter.default.removeObserver(castStateObservation)
    }
    // Nothing can complete these once the delegate is gone; resume them so
    // awaiting tasks do not hang teardown. Tables are drained first so a late
    // delegate callback for a cancelled request finds nothing to resume.
    let abandoned = Array(pendingRequestObjects.values)
    pendingRequestObjects.removeAll()
    let continuations = Array(pendingRequests.values)
    pendingRequests.removeAll()
    for request in abandoned { request.cancel() }
    for continuation in continuations {
      continuation.resume(throwing: PutioCastControllerError(failure: .receiver))
    }
  }

  func startDiscovery() {
    let discovery = GCKCastContext.sharedInstance().discoveryManager
    if !discovery.discoveryActive { discovery.startDiscovery() }
    localNetwork.start { [weak self] denied in
      guard let self, denied != localNetworkDenied else { return }
      localNetworkDenied = denied
      castStateChanged()
    }
  }

  func connect(toDevice id: PutioCastDevice.ID) {
    let sessionManager = GCKCastContext.sharedInstance().sessionManager
    guard sessionManager.currentSession != nil else {
      startSession(on: id)
      return
    }
    pendingDeviceID = id
    endCurrentSession()
  }

  private func startPendingSession() {
    guard let pendingDeviceID else { return }
    self.pendingDeviceID = nil
    startSession(on: pendingDeviceID)
  }

  private func startSession(on id: PutioCastDevice.ID) {
    let context = GCKCastContext.sharedInstance()
    guard let device = context.discoveryManager.device(withUniqueID: id) else { return }
    _ = context.sessionManager.startSession(with: device)
  }

  /// A new load supersedes every request still in flight (an earlier load or
  /// a stop), so a late completion cannot idle the receiver under this media
  /// or play the previous file after this one was accepted.
  func load(_ media: PutioCastMedia, startSeconds: Int, autoplay: Bool, activeTrackIDs: [Int])
    async throws
  {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    abandonPendingRequests()
    loadedFileID = nil
    let sessionAppID =
      GCKCastContext.sharedInstance().sessionManager.currentCastSession?.applicationMetadata?
      .applicationID
    let receiverLoad = Self.putioReceiverLoad(
      for: media, startSeconds: startSeconds,
      onPutioReceiver: sessionAppID == Self.putioReceiverAppID)
    let builder: GCKMediaInformationBuilder
    if receiverLoad != nil {
      builder = GCKMediaInformationBuilder()
      builder.contentID = String(media.id.rawValue)
      builder.streamType = .buffered
    } else {
      builder = GCKMediaInformationBuilder(contentURL: media.url)
      // put.io playlists carry no stable duration, so the receiver derives
      // seekability from the stream.
      builder.streamType = .none
    }
    builder.contentType = media.contentType
    if media.durationSeconds > 0 { builder.streamDuration = media.durationSeconds }
    let metadata: GCKMediaMetadata
    switch media.kind {
    case .video: metadata = GCKMediaMetadata(metadataType: .movie)
    case .audio: metadata = GCKMediaMetadata(metadataType: .musicTrack)
    }
    metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
    metadata.setString("put.io", forKey: kGCKMetadataKeySubtitle)
    if let artworkURL = media.artworkURL {
      metadata.addImage(GCKImage(url: artworkURL, width: 640, height: 360))
    }
    builder.metadata = metadata
    // Status updates are attributed to this file only while the receiver
    // still reports our tag; another sender's media publishes as nil.
    builder.customData = [Self.fileIDKey: media.id.rawValue]
    let request = GCKMediaLoadRequestDataBuilder()
    request.mediaInformation = builder.build()
    request.autoplay = NSNumber(value: autoplay)
    request.startTime = TimeInterval(startSeconds)
    request.customData = receiverLoad
    if !activeTrackIDs.isEmpty {
      request.activeTrackIDs = activeTrackIDs.map { NSNumber(value: $0) }
    }
    try await perform(client.loadMedia(with: request.build()))
    // Status updates carry this file only once the receiver accepted it; the
    // status that arrived during the request is replayed so controls enable.
    loadedFileID = media.id
    publishStatus(client.mediaStatus)
  }

  var approximatePositionSeconds: Double? {
    guard let fileID = loadedFileID, let client = remoteMediaClient,
      let mediaStatus = client.mediaStatus,
      let tag = mediaStatus.mediaInformation?.customData as? [String: Any],
      tag[Self.fileIDKey] as? Int == fileID.rawValue,
      [.playing, .paused, .buffering].contains(mediaStatus.playerState)
    else { return nil }
    let position = client.approximateStreamPosition()
    return position.isFinite ? position : nil
  }

  func setActiveTrackIDs(_ ids: [Int]) async throws {
    guard let client = remoteMediaClient, loadedFileID != nil else {
      throw PutioCastControllerError(failure: .receiver)
    }
    try await perform(client.setActiveTrackIDs(ids.map { NSNumber(value: $0) }))
    publishStatus(client.mediaStatus)
  }

  func refreshStatus() {
    _ = remoteMediaClient?.requestStatus()
  }

  func play() async throws {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    try await perform(client.play())
  }

  func pause() async throws {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    try await perform(client.pause())
  }

  func seek(toSeconds seconds: Double) async throws {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    let options = GCKMediaSeekOptions()
    options.interval = seconds
    try await perform(client.seek(with: options))
  }

  func stop() async throws {
    loadedFileID = nil
    guard let client = remoteMediaClient else { return }
    try await perform(client.stop())
  }

  func endSession() {
    pendingDeviceID = nil
    endCurrentSession()
  }

  private func endCurrentSession() {
    abandonPendingRequests()
    loadedFileID = nil
    _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
  }

  // MARK: SDK plumbing

  private var remoteMediaClient: GCKRemoteMediaClient? {
    GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
  }

  /// Bridges a `GCKRequest` to async. Cancelling the awaiting task cancels
  /// the request, which the SDK reports back as an abort.
  private func perform(_ request: GCKRequest) async throws {
    request.delegate = self
    let id = request.requestID
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        pendingRequests[id] = continuation
        pendingRequestObjects[id] = request
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.pendingRequestObjects[id]?.cancel() }
    }
  }

  /// Continuations leave the table before anything resumes them, so a late
  /// delegate callback for a cancelled request finds nothing to resume.
  private func abandonPendingRequests() {
    let abandoned = Array(pendingRequestObjects.values)
    pendingRequestObjects.removeAll()
    let continuations = Array(pendingRequests.values)
    pendingRequests.removeAll()
    for request in abandoned { request.cancel() }
    for continuation in continuations {
      continuation.resume(throwing: PutioCastControllerError(failure: .receiver))
    }
  }

  private func finish(_ request: GCKRequest, error: Error?) {
    pendingRequestObjects[request.requestID] = nil
    guard let continuation = pendingRequests.removeValue(forKey: request.requestID) else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  private func castStateChanged() {
    let context = GCKCastContext.sharedInstance()
    let device = context.sessionManager.currentCastSession?.device
    let name = device?.friendlyName ?? String(localized: "Chromecast")
    let audioOnly = device.map(Self.isAudioOnly) ?? false
    let next: PutioCastConnection =
      switch context.castState {
      case .noDevicesAvailable: localNetworkDenied ? .localNetworkDenied : .unavailable
      case .notConnected: .disconnected
      case .connecting: .connecting(deviceName: name)
      case .connected: .connected(deviceName: name, audioOnly: audioOnly)
      @unknown default: .disconnected
      }
    discoveryChanged()
    guard next != connection else { return }
    connection = next
    onConnectionChanged?(next)
  }

  private func discoveryChanged() {
    let context = GCKCastContext.sharedInstance()
    let manager = context.discoveryManager
    let selectedID = context.sessionManager.currentCastSession?.device.uniqueID
    let devices = (0..<manager.deviceCount).map { index in
      Self.device(manager.device(at: index), selectedID: selectedID)
    }
    let next = PutioCastDiscovery(
      devices: devices, isSearching: manager.discoveryState == .running)
    guard next != discovery else { return }
    discovery = next
    onDiscoveryChanged?(next)
  }

  private static func isAudioOnly(_ device: GCKDevice) -> Bool {
    switch device.type {
    case .speaker, .speakerGroup: true
    default: !device.hasCapabilities(.videoOut)
    }
  }

  private static func device(_ device: GCKDevice, selectedID: String?) -> PutioCastDevice {
    let audioOnly = isAudioOnly(device)
    let kind: PutioCastDevice.Kind =
      switch device.type {
      case .TV: .tv
      case .speaker, .speakerGroup: .speaker
      case .generic, .nearbyUnpaired: audioOnly ? .speaker : .other
      @unknown default: .other
      }
    return PutioCastDevice(
      id: device.uniqueID,
      name: device.friendlyName ?? device.modelName ?? String(localized: "Chromecast"),
      model: device.modelName, kind: kind, audioOnly: audioOnly,
      isSelected: device.uniqueID == selectedID)
  }

  private static let fileIDKey = "putio_file_id"

  /// The put.io receiver builds a video's stream from its file id and the
  /// download token, so the token never rides in a URL. Audio and any other
  /// receiver keep the plain load.
  static func putioReceiverLoad(
    for media: PutioCastMedia, startSeconds: Int, onPutioReceiver: Bool
  ) -> [String: Any]? {
    guard onPutioReceiver, case .video = media.kind, let token = media.downloadToken,
      !token.isEmpty
    else { return nil }
    return [
      "fileId": media.id.rawValue, "method": "hls", "position": max(0, startSeconds),
      "token": token,
    ]
  }

  private func publishStatus(_ mediaStatus: GCKMediaStatus?) {
    guard let mediaStatus, let fileID = loadedFileID,
      let tag = mediaStatus.mediaInformation?.customData as? [String: Any],
      tag[Self.fileIDKey] as? Int == fileID.rawValue
    else {
      onMediaStatusChanged?(nil)
      return
    }
    let state: PutioCastPlayerState =
      switch mediaStatus.playerState {
      case .idle: mediaStatus.idleReason == .error ? .failed : .idle
      case .loading: .loading
      case .buffering: .buffering
      case .playing: .playing
      case .paused: .paused
      // Unknown is transitional, not end of playback; only a real idle
      // status ends the session surface.
      case .unknown: .loading
      @unknown default: .loading
      }
    let tracks = mediaStatus.mediaInformation?.mediaTracks ?? []
    let audioTracks = tracks.filter { $0.type == .audio }
    let textTracks = tracks.filter { $0.type == .text && $0.textSubtype != .metadata }
    onMediaStatusChanged?(
      PutioCastMediaStatus(
        fileID: fileID, playerState: state, positionSeconds: mediaStatus.streamPosition,
        durationSeconds: mediaStatus.mediaInformation?.streamDuration ?? 0,
        audioTracks: audioTracks.map {
          PutioCastAudioTrack(id: $0.identifier, languageCode: $0.languageCode, name: $0.name)
        },
        textTracks: textTracks.map {
          PutioCastTextTrack(id: $0.identifier, languageCode: $0.languageCode, name: $0.name)
        },
        activeTrackIDs: (mediaStatus.activeTrackIDs ?? []).map(\.intValue)))
  }
}

extension PutioGoogleCastController: GCKSessionManagerListener {
  nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession)
  {
    MainActor.assumeIsolated {
      session.remoteMediaClient?.add(self)
      castStateChanged()
    }
  }

  nonisolated func sessionManager(
    _ sessionManager: GCKSessionManager, didResumeSession session: GCKSession
  ) {
    MainActor.assumeIsolated {
      session.remoteMediaClient?.add(self)
      castStateChanged()
      publishStatus(session.remoteMediaClient?.mediaStatus)
    }
  }

  nonisolated func sessionManager(
    _ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?
  ) {
    MainActor.assumeIsolated {
      loadedFileID = nil
      abandonPendingRequests()
      castStateChanged()
      startPendingSession()
    }
  }

  nonisolated func sessionManager(
    _ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error
  ) {
    MainActor.assumeIsolated {
      castStateChanged()
      startPendingSession()
    }
  }
}

extension PutioGoogleCastController: GCKDiscoveryManagerListener {
  nonisolated func didStartDiscovery(forDeviceCategory deviceCategory: String) {
    MainActor.assumeIsolated { discoveryChanged() }
  }

  nonisolated func didUpdateDeviceList() {
    MainActor.assumeIsolated { discoveryChanged() }
  }
}

extension PutioGoogleCastController: GCKRemoteMediaClientListener {
  nonisolated func remoteMediaClient(
    _ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?
  ) {
    MainActor.assumeIsolated { publishStatus(mediaStatus) }
  }
}

extension PutioGoogleCastController: GCKRequestDelegate {
  nonisolated func requestDidComplete(_ request: GCKRequest) {
    MainActor.assumeIsolated { finish(request, error: nil) }
  }

  nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
    MainActor.assumeIsolated {
      finish(request, error: PutioCastControllerError(failure: .receiver))
    }
  }

  nonisolated func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
    MainActor.assumeIsolated {
      finish(request, error: PutioCastControllerError(failure: .receiver))
    }
  }
}
