import Foundation
import GoogleCast
import PutioSDK

class ChromecastManager: NSObject {
    static let sharedInstance = ChromecastManager()

    struct CastError {
        var reason: CastErrorReason
    }

    enum CastErrorReason: Int {
        case fileNotFound, fileNeedsConvert, missingMetadata

        var playbackError: AnalyticsEvent.PlaybackError {
            switch self {
            case .fileNotFound: return .source
            case .fileNeedsConvert: return .unsupported
            case .missingMetadata: return .media
            }
        }
    }

    var castingFileId: Int?
    var timer: Timer?
    private let playbackTracker = CastPlaybackTracker()

    var debug: Bool = false

    var userSettings: UserSettings? = {
        PutioRealm.open(context: "ChromecastManager.userSettings")?.objects(User.self).first?.settings
    }()

    var userConfig: UserConfig? = {
        PutioRealm.open(context: "ChromecastManager.userConfig")?.objects(UserConfig.self).first
    }()

    func setup() {
        let discoveryCriteria = GCKDiscoveryCriteria(applicationID: CHROMECAST_RECEIVER_APP_ID)
        let options = GCKCastOptions(discoveryCriteria: discoveryCriteria)
        options.disableAnalyticsLogging = true

        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        GCKCastContext.sharedInstance().sessionManager.add(self)

        configureLogger()
        stylize()
    }

    private func configureLogger() {
        let logFilter = GCKLoggerFilter()
        let classesToLog = [
            "GCKDeviceScanner",
            "GCKDeviceProvider",
            "GCKDiscoveryManager",
            "GCKCastChannel",
            "GCKMediaControlChannel",
            "GCKUICastButton",
            "GCKUIMediaController",
            "NSMutableDictionary"
        ]

        let loggingLevel: GCKLoggerLevel = debug ? .debug : .none
        logFilter.setLoggingLevel(loggingLevel, forClasses: classesToLog)

        GCKLogger.sharedInstance().filter = logFilter
        GCKLogger.sharedInstance().delegate = self
    }

    private func stylize() {
        let castStyle = GCKUIStyle.sharedInstance()
        let castViews = castStyle.castViews

        castViews.backgroundColor = UIColor.Putio.Surface.appBg
        castViews.deviceControl.sliderProgressColor = UIColor.Putio.Yellow.solid

        castViews.headingTextColor = UIColor.Putio.Neutral.text
        castViews.headingTextShadowColor = .clear

        castViews.captionTextColor = UIColor.Putio.Neutral.textSecondary
        castViews.captionTextShadowColor = .clear

        castViews.bodyTextColor = UIColor.Putio.Neutral.text
        castViews.bodyTextShadowColor = .clear

        castViews.buttonTextColor = UIColor.Putio.Yellow.textSecondary
        castViews.buttonTextShadowColor = .clear

        castViews.iconTintColor = UIColor.Putio.Neutral.text

        // The expanded controller renders over media artwork: fixed colors
        // by token policy (over-media exception).
        let expandedController = castViews.mediaControl.expandedController
        expandedController.backgroundColor = .black
        expandedController.headingTextColor = .white
        expandedController.captionTextColor = .gray
        expandedController.bodyTextColor = .white
        expandedController.iconTintColor = .white

        castViews.sliderProgressColor = UIColor.Putio.Yellow.solid
        castViews.sliderSecondaryProgressColor = UIColor.Putio.Surface.appBg
        castViews.sliderUnseekableProgressColor = UIColor.Putio.Neutral.line
        castViews.sliderTooltipBackgroundColor = UIColor.Putio.Neutral.componentBg

        castViews.mediaControl.backgroundColor = UIColor.Putio.Neutral.componentBg
        castViews.mediaControl.headingTextFont = .systemFont(ofSize: 18.0)
        castViews.mediaControl.iconTintColor = UIColor.Putio.Yellow.textSecondary
        castViews.mediaControl.miniController.headingTextFont = .systemFont(ofSize: 14.0)

        castStyle.apply()
    }

    func isActive() -> Bool {
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession != nil
    }

    func createGCKMediaMetadata(for file: PutioFile) -> GCKMediaMetadata {
        let metadata = GCKMediaMetadata(metadataType: GCKMediaMetadataType.movie)
        metadata.setString(file.name, forKey: kGCKMetadataKeyTitle)
        metadata.setString("put.io/files/\(file.id)", forKey: kGCKMetadataKeySubtitle)

        if let image = createMetadataImage(for: file) {
            metadata.addImage(image)
        }

        return metadata
    }

    func createMetadataImage(for file: PutioFile) -> GCKImage? {
        guard let imageURL = URL(string: file.screenshot) else {
            InternalFailurePresenter.log("Unable to construct Chromecast screenshot URL for file \(file.id)")
            return nil
        }

        return GCKImage(url: imageURL, width: 640, height: 360)
    }

    func createGCKMediaLoadOptions(for file: PutioFile) -> GCKMediaLoadOptions {
        let mediaLoadOptions = GCKMediaLoadOptions()
        mediaLoadOptions.autoplay = true
        mediaLoadOptions.playPosition = TimeInterval(file.startFrom)
        return mediaLoadOptions
    }

    func createGCKMediaInformation(
        for file: PutioFile,
        metadata: GCKMediaMetadata,
        mediaLoadOptions: GCKMediaLoadOptions,
        completion: @escaping (_ result: GCKMediaInformation?, _ error: Error?) -> Void
    ) {
        guard let fileMetadata = file.metaData else {
            return completion(nil, NSError(domain: "Missing Metadata", code: 0, userInfo: nil))
        }

        let mediaInfo = GCKMediaInformationBuilder()
        mediaInfo.metadata = metadata

        if userConfig?.chromecastPlaybackType == "hls" {
            log.debug("Chromecast: playing HLS")
            mediaInfo.contentID = file.getHlsStreamURL(downloadToken: api.mediaToken).absoluteString
            mediaInfo.streamType = .none
            mediaInfo.contentType = "video/m3u"
            return completion(mediaInfo.build(), nil)
        }

        mediaInfo.contentID = file.hasMp4 ? file.mp4StreamURL : file.streamURL
        mediaInfo.streamType = GCKMediaStreamType.buffered
        mediaInfo.contentType = "video/mp4"
        mediaInfo.streamDuration = TimeInterval(fileMetadata.duration)

        api.getSubtitles(fileID: file.id) { result in
            switch result {
            case .success(let subtitles):
                var mediaTracks: [GCKMediaTrack] = []

                if !subtitles.isEmpty {
                    for (index, subtitle) in subtitles.enumerated() {
                        let track = GCKMediaTrack(
                            identifier: index,
                            contentIdentifier: "\(subtitle.url)&format=webvtt",
                            contentType: "text/vtt",
                            type: .text,
                            textSubtype: .captions,
                            name: "\(subtitle.language) - \(subtitle.name)",
                            languageCode: subtitle.languageCode,
                            customData: nil
                        )

                        if let mediaTrack = track {
                            mediaTracks.append(mediaTrack)
                            mediaInfo.mediaTracks = mediaTracks
                        }
                    }

                    let shouldAutoSelectSubtitle = (self.userSettings?.dontAutoSelectSubtitles ?? false) ? false : true
                    log.debug("Chromecast: shouldAutoSelectSubtitle -> \(shouldAutoSelectSubtitle)")
                    mediaLoadOptions.activeTrackIDs =  shouldAutoSelectSubtitle ? [0] : nil
                }

                completion(mediaInfo.build(), nil)

            case .failure(let error):
                completion(nil, error)
            }
        }
    }

    func castVideo(fileID: Int, completion reportResult: @escaping (_ success: Bool, _ error: CastError?) -> Void) {
        let currentCastSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        let session = AccountNoticeStore.shared.session
        var castFile: PutioFile?
        // The put.io request behind a failure, which says more than its CastErrorReason.
        var requestError: PutioSDKError?
        let completion: (Bool, CastError?) -> Void = { success, error in
            if let error {
                let failure = requestError.map { AnalyticsEvent.PlaybackError($0) } ?? error.reason.playbackError
                ProductAnalytics.capture(.playbackFailed(self.castPlayback(for: castFile), failure), startedIn: session)
            }
            reportResult(success, error)
        }

        if timer != nil {
            timer?.invalidate()
        }

        api.getFiles(parentID: fileID) { result in
            switch result {
            case .success(let data):
                guard let file = data.parent else {
                    return completion(false, CastError(reason: .fileNotFound))
                }
                castFile = file

                if file.needConvert && file.metaData?.codec != "h264" {
                    return completion(false, CastError(reason: .fileNeedsConvert))
                }

                let metadata = self.createGCKMediaMetadata(for: file)
                let mediaLoadOptions = self.createGCKMediaLoadOptions(for: file)

                self.createGCKMediaInformation(for: file, metadata: metadata, mediaLoadOptions: mediaLoadOptions) { (mediaInformation, error) in
                    guard let mediaInformation = mediaInformation else {
                        requestError = error as? PutioSDKError
                        return completion(false, CastError(reason: .missingMetadata))
                    }

                    self.castingFileId = fileID
                    self.timer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(self.saveVideoTime), userInfo: nil, repeats: true)

                    if let load = currentCastSession?.remoteMediaClient?.loadMedia(mediaInformation, with: mediaLoadOptions) {
                        load.delegate = self
                        self.playbackTracker.loadStarted(load, playback: self.castPlayback(for: file), session: session)
                    }
                    GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()

                    completion(true, nil)
                }

            case .failure(let error):
                requestError = error
                completion(false, CastError(reason: .fileNotFound))
            }
        }
    }

    private func castPlayback(for file: PutioFile?) -> AnalyticsEvent.Playback {
        let streamMethod: AnalyticsEvent.StreamMethod
        if userConfig?.chromecastPlaybackType == "hls" {
            streamMethod = .hls
        } else {
            streamMethod = file?.hasMp4 == false ? .progressive : .mp4
        }
        return AnalyticsEvent.Playback(media: .video, streamMethod: streamMethod, player: .chromecast)
    }

    @objc private func saveVideoTime() {
        guard let userSettings = PutioRealm.open(context: "ChromecastManager.saveVideoTime")?.objects(User.self).first?.settings,
            userSettings.rememberVideoTime,
            let id = castingFileId,
            let time = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.approximateStreamPosition() else { return }

        let timeInt = Int(time)

        if timeInt == 0 {
            timer?.invalidate()
        } else {
            api.setStartFrom(fileID: id, time: timeInt, completion: { _ in })
        }
    }

    func logError(error: Error) {
        if debug { log.error(error) }
    }
}

extension ChromecastManager: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        if timer != nil { timer?.invalidate() }
        playbackTracker.sessionEnded()
        if let error = error { logError(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        if timer != nil { timer?.invalidate() }
        playbackTracker.sessionEnded()
        if let error = error { logError(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        if timer != nil { timer?.invalidate() }
        logError(error: error)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        if timer != nil { timer?.invalidate() }
        logError(error: error)
    }
}

extension ChromecastManager: GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
        let status = client?.mediaStatus.map { CastPlaybackTracker.Status($0) }
        guard playbackTracker.loadCompleted(request, status: status), let client else { return }
        client.remove(self)
        client.add(self)
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        playbackTracker.loadFailed(request, error: error)
    }

    /// Replaced or dropped, so neither a start nor a failure.
    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        playbackTracker.loadAborted(request)
    }
}

extension ChromecastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { return }
        playbackTracker.update(CastPlaybackTracker.Status(mediaStatus))
    }
}

final class CastPlaybackTracker {
    struct Status {
        let playerState: GCKMediaPlayerState
        let idleReason: GCKMediaPlayerIdleReason
        let mediaSessionID: Int

        init(playerState: GCKMediaPlayerState, idleReason: GCKMediaPlayerIdleReason = .none, mediaSessionID: Int) {
            self.playerState = playerState
            self.idleReason = idleReason
            self.mediaSessionID = mediaSessionID
        }

        init(_ status: GCKMediaStatus) {
            self.init(playerState: status.playerState, idleReason: status.idleReason, mediaSessionID: status.mediaSessionID)
        }

        var activeMediaSessionID: Int? {
            guard mediaSessionID != 0, [.playing, .paused, .buffering, .loading].contains(playerState) else { return nil }
            return mediaSessionID
        }
    }

    private struct Load {
        let playback: AnalyticsEvent.Playback
        let session: Int
    }

    private struct Playing {
        let load: Load
        let startedAt: Date
        var mediaSessionID: Int?
    }

    private let capture: (AnalyticsEvent, Int) -> Void
    private let report: (SentryTelemetry.PlaybackFailure, Error?, Int) -> Void
    private let now: () -> Date
    private var pending: (request: AnyObject, load: Load)?
    private var playing: Playing?

    init(
        capture: @escaping (AnalyticsEvent, Int) -> Void = ProductAnalytics.capture(_:startedIn:),
        report: @escaping (SentryTelemetry.PlaybackFailure, Error?, Int) -> Void = SentryTelemetry.capture(_:error:startedIn:),
        now: @escaping () -> Date = Date.init
    ) {
        self.capture = capture
        self.report = report
        self.now = now
    }

    func loadStarted(_ request: AnyObject, playback: AnalyticsEvent.Playback, session: Int) {
        pending = (request, Load(playback: playback, session: session))
        playing = nil
    }

    func loadCompleted(_ request: AnyObject, status: Status?) -> Bool {
        guard let load = takePending(request) else { return false }
        capture(.playbackStarted(load.playback), load.session)
        playing = Playing(load: load, startedAt: now(), mediaSessionID: status?.activeMediaSessionID)
        return true
    }

    func loadFailed(_ request: AnyObject, error: GCKError) {
        guard let load = takePending(request) else { return }
        capture(.playbackFailed(load.playback, .init(error)), load.session)
        report(.init(signal: .castLoadFailed, playback: load.playback), error, load.session)
    }

    func loadAborted(_ request: AnyObject) {
        _ = takePending(request)
    }

    func update(_ status: Status) {
        guard let current = playing else { return }
        guard let mediaSessionID = current.mediaSessionID else {
            playing?.mediaSessionID = status.activeMediaSessionID
            return
        }
        guard status.playerState == .idle, status.mediaSessionID == mediaSessionID else { return }
        playing = nil
        guard status.idleReason == .finished else { return }
        capture(.playbackEnded(current.load.playback, .init(seconds: now().timeIntervalSince(current.startedAt))), current.load.session)
    }

    func sessionEnded() {
        playing = nil
    }

    private func takePending(_ request: AnyObject) -> Load? {
        guard let pending, pending.request === request else { return nil }
        self.pending = nil
        return pending.load
    }
}

extension ChromecastManager: GCKLoggerDelegate {
    func logMessage(_ message: String, at level: GCKLoggerLevel, fromFunction function: String, location: String) {
        if debug { log.debug("\(function) - \(message)") }
    }
}
