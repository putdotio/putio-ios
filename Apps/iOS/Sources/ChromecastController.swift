import Foundation
import GoogleCast
import PutioCore
import SwiftUI
import UIKit

/// The Google Cast SDK behind `PutioCastControlling`. The shared context is
/// configured once per process with the effective receiver ID; discovery is
/// scoped to that receiver and starts on the first Cast button tap so the
/// local-network prompt appears with intent, not at launch.
@MainActor
final class PutioGoogleCastController: NSObject, PutioCastControlling {
  private(set) var connection: PutioCastConnection = .unavailable
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
  let providesSystemCastButton = true

  private var loadedFileID: PutioFileID?
  private var loadedSubtitles: [PutioCastSubtitle] = []
  private var castStateObservation: NSObjectProtocol?
  private var pendingRequests: [Int: CheckedContinuation<Void, Error>] = [:]
  private var pendingRequestObjects: [Int: GCKRequest] = [:]

  static func configureSharedContext(receiverAppID: String) {
    guard !GCKCastContext.isSharedInstanceInitialized() else { return }
    let criteria = GCKDiscoveryCriteria(applicationID: receiverAppID)
    let options = GCKCastOptions(discoveryCriteria: criteria)
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
    castStateObservation = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.gckCastStateDidChange, object: context, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.castStateChanged() }
    }
    if let client = context.sessionManager.currentCastSession?.remoteMediaClient {
      client.add(self)
    }
    castStateChanged()
  }

  func presentDevicePicker() {
    GCKCastContext.sharedInstance().presentCastDialog()
  }

  func load(_ media: PutioCastMedia, subtitleKey: String?) async throws {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    loadedFileID = media.id
    loadedSubtitles = media.subtitles
    let builder = GCKMediaInformationBuilder(contentURL: media.url)
    builder.streamType = media.playbackType == .hls ? .none : .buffered
    builder.contentType = media.playbackType == .hls ? "application/x-mpegURL" : "video/mp4"
    if media.durationSeconds > 0 { builder.streamDuration = media.durationSeconds }
    let metadata = GCKMediaMetadata(metadataType: .movie)
    metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
    metadata.setString("put.io", forKey: kGCKMetadataKeySubtitle)
    if let artworkURL = media.artworkURL {
      metadata.addImage(GCKImage(url: artworkURL, width: 640, height: 360))
    }
    builder.metadata = metadata
    builder.mediaTracks = media.subtitles.enumerated().compactMap { index, subtitle in
      GCKMediaTrack(
        identifier: index + 1, contentIdentifier: subtitle.url.absoluteString,
        contentType: "text/vtt", type: .text, textSubtype: .subtitles,
        name: "\(subtitle.language) - \(subtitle.name)", languageCode: subtitle.languageCode,
        customData: nil)
    }
    let request = GCKMediaLoadRequestDataBuilder()
    request.mediaInformation = builder.build()
    request.autoplay = true
    request.startTime = TimeInterval(media.startFromSeconds)
    if let subtitleKey, let trackID = trackID(for: subtitleKey) {
      request.activeTrackIDs = [NSNumber(value: trackID)]
    }
    try await perform(client.loadMedia(with: request.build()))
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

  func setSubtitle(key: String?) async throws {
    guard let client = remoteMediaClient else { throw PutioCastControllerError(failure: .receiver) }
    let ids = key.flatMap(trackID(for:)).map { [NSNumber(value: $0)] } ?? []
    try await perform(client.setActiveTrackIDs(ids))
  }

  func stop() async throws {
    guard let client = remoteMediaClient else { return }
    loadedFileID = nil
    try await perform(client.stop())
  }

  func endSession() {
    loadedFileID = nil
    _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
  }

  // MARK: SDK plumbing

  private var remoteMediaClient: GCKRemoteMediaClient? {
    GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
  }

  private func trackID(for key: String) -> Int? {
    loadedSubtitles.firstIndex { $0.key == key }.map { $0 + 1 }
  }

  private func perform(_ request: GCKRequest) async throws {
    request.delegate = self
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pendingRequests[request.requestID] = continuation
      pendingRequestObjects[request.requestID] = request
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
    let name = context.sessionManager.currentCastSession?.device.friendlyName ?? "Chromecast"
    let next: PutioCastConnection =
      switch context.castState {
      case .noDevicesAvailable: .unavailable
      case .notConnected: .disconnected
      case .connecting: .connecting(deviceName: name)
      case .connected: .connected(deviceName: name)
      @unknown default: .disconnected
      }
    guard next != connection else { return }
    connection = next
    onConnectionChanged?(next)
  }

  private func publishStatus(_ mediaStatus: GCKMediaStatus?) {
    guard let mediaStatus, let fileID = loadedFileID else {
      onMediaStatusChanged?(nil)
      return
    }
    let state: PutioCastPlayerState =
      switch mediaStatus.playerState {
      case .idle: .idle
      case .loading: .loading
      case .buffering: .buffering
      case .playing: .playing
      case .paused: .paused
      case .unknown: .idle
      @unknown default: .idle
      }
    let subtitles = loadedSubtitles
    let activeKey = mediaStatus.activeTrackIDs?.lazy.compactMap { id -> String? in
      let index = id.intValue - 1
      guard subtitles.indices.contains(index) else { return nil }
      return subtitles[index].key
    }.first
    onMediaStatusChanged?(
      PutioCastMediaStatus(
        fileID: fileID, playerState: state, positionSeconds: mediaStatus.streamPosition,
        durationSeconds: mediaStatus.mediaInformation?.streamDuration ?? 0,
        activeSubtitleKey: activeKey))
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
      for (id, continuation) in pendingRequests {
        pendingRequests[id] = nil
        continuation.resume(throwing: PutioCastControllerError(failure: .receiver))
      }
      pendingRequestObjects.removeAll()
      castStateChanged()
    }
  }

  nonisolated func sessionManager(
    _ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error
  ) {
    MainActor.assumeIsolated { castStateChanged() }
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

/// Google's Cast button, which owns discovery, the device picker, and the
/// connected/disconnected glyph state.
struct PutioGoogleCastButton: UIViewRepresentable {
  func makeUIView(context: Context) -> GCKUICastButton {
    let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    button.tintColor = UIColor(PutioTheme.Colors.accent)
    button.accessibilityIdentifier = "cast.button"
    return button
  }

  func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}
