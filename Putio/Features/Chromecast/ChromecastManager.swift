import Foundation
import GoogleCast
import PutioSDK

class ChromecastManager: NSObject {
    static let sharedInstance = ChromecastManager()

    private struct ReceiverLoad {
        let fileID: Int
        let request: GCKRequest
        var accepted = false
        var mediaSessionID: Int?
        var fallback: DispatchWorkItem?
    }

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
    private(set) var receiver: CastReceiver = .defaultMedia
    private var receiverChannel: PutioCastChannel?
    private var receiverLoad: ReceiverLoad?
    private let playbackTracker = CastPlaybackTracker()

    var debug: Bool = false

    var userConfig: UserConfig? {
        PutioRealm.open(context: "ChromecastManager.userConfig")?.objects(UserConfig.self).first
    }

    func setup() {
        guard !GCKCastContext.isSharedInstanceInitialized() else { return }
        receiver = CastReceiver(usesPutioReceiver: userConfig?.usesPutioCastReceiver ?? false)
        let discoveryCriteria = GCKDiscoveryCriteria(applicationID: receiver.applicationID)
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
            InternalFailurePresenter.log("Unable to construct Chromecast screenshot URL for file \(file.id)", context: "ChromecastManager.createMetadataImage")
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

    func sessionReceiver(_ session: GCKCastSession?) -> CastReceiver {
        CastReceiver(applicationID: session?.applicationMetadata?.applicationID) ?? .defaultMedia
    }

    func putioCastLoad(for file: PutioFile, token: String, hidesSubtitles: Bool) -> PutioCastLoad {
        PutioCastLoad(
            fileID: file.id,
            method: userConfig?.chromecastPlaybackType == "hls" ? .hls : .file,
            position: file.startFrom,
            token: token,
            hidesSubtitles: hidesSubtitles
        )
    }

    func createGCKMediaInformation(
        for file: PutioFile,
        receiver: CastReceiver,
        metadata: GCKMediaMetadata,
        mediaLoadOptions: GCKMediaLoadOptions,
        completion: @escaping (_ result: GCKMediaInformation?, _ error: Error?) -> Void
    ) {
        guard let fileMetadata = file.metaData else {
            return completion(nil, NSError(domain: "Missing Metadata", code: 0, userInfo: nil))
        }

        let mediaInfo = GCKMediaInformationBuilder()
        mediaInfo.metadata = metadata

        let settings = PutioRealm.open(context: "ChromecastManager.createGCKMediaInformation")?.objects(User.self).first?.settings
        let hideSubtitles = settings?.hideSubtitles ?? false

        if receiver == .putio {
            guard let mediaToken = api.mediaToken else { return completion(nil, MediaTokenError.unavailable) }
            mediaInfo.contentID = String(file.id)
            mediaInfo.streamType = .buffered
            mediaInfo.contentType = "application/x-mpegurl"
            mediaInfo.streamDuration = TimeInterval(fileMetadata.duration)
            mediaLoadOptions.customData = putioCastLoad(for: file, token: mediaToken, hidesSubtitles: hideSubtitles).customData
            return completion(mediaInfo.build(), nil)
        }

        if userConfig?.chromecastPlaybackType == "hls" {
            log.debug("Chromecast: playing HLS")
            guard let mediaToken = api.mediaToken else { return completion(nil, MediaTokenError.unavailable) }
            mediaInfo.contentID = file.getHlsStreamURL(downloadToken: mediaToken)
                .applyingSubtitlePreference(hideSubtitles: hideSubtitles)
                .absoluteString
            mediaInfo.streamType = .none
            mediaInfo.contentType = "video/m3u"
            return completion(mediaInfo.build(), nil)
        }

        mediaInfo.contentID = file.hasMp4 ? file.mp4StreamURL : file.streamURL
        mediaInfo.streamType = GCKMediaStreamType.buffered
        mediaInfo.contentType = "video/mp4"
        mediaInfo.streamDuration = TimeInterval(fileMetadata.duration)

        guard !hideSubtitles else {
            return completion(mediaInfo.build(), nil)
        }

        api.getSubtitles(fileID: file.id) { result in
            switch result {
            case .success(let response):
                let sidecars = response.subtitles.compactMap { subtitle in
                    subtitle.castableURL.map { (subtitle: subtitle, url: $0) }
                }
                let labels = PutioSubtitle.trackLabels(for: sidecars.map(\.subtitle))
                mediaInfo.mediaTracks = sidecars.enumerated().compactMap { index, sidecar in
                    GCKMediaTrack(
                        identifier: index,
                        contentIdentifier: sidecar.url.absoluteString,
                        contentType: "text/vtt",
                        type: .text,
                        textSubtype: .captions,
                        name: labels[index],
                        languageCode: sidecar.subtitle.languageCode,
                        customData: nil
                    )
                }

                let autoSelect = !(settings?.dontAutoSelectSubtitles ?? false)
                let defaultIndex = sidecars.firstIndex { $0.subtitle.key == response.defaultKey }
                log.debug("Chromecast: autoSelect subtitle -> \(autoSelect)")
                mediaLoadOptions.activeTrackIDs = autoSelect ? defaultIndex.map { [NSNumber(value: $0)] } : nil

                completion(mediaInfo.build(), nil)

            case .failure(let error):
                completion(nil, error)
            }
        }
    }

    func castVideo(fileID: Int, completion reportResult: @escaping (_ success: Bool, _ error: CastError?) -> Void) {
        let currentCastSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        var receiver = sessionReceiver(currentCastSession)
        let session = AccountNoticeStore.shared.session
        var castFile: PutioFile?
        // The put.io request behind a failure, which says more than its CastErrorReason.
        var requestError: PutioSDKError?
        let completion: (Bool, CastError?) -> Void = { success, error in
            if let error {
                let failure = requestError.map { AnalyticsEvent.PlaybackError($0) } ?? error.reason.playbackError
                ProductAnalytics.capture(.playbackFailed(self.castPlayback(for: castFile, receiver: receiver), failure), startedIn: session)
            }
            reportResult(success, error)
        }

        if timer != nil {
            timer?.invalidate()
        }

        let needsSignedStreamURLs = receiver != .putio && userConfig?.chromecastPlaybackType != "hls"
        let query = PutioFilesListQuery(
            streamURLParent: needsSignedStreamURLs,
            mp4StreamURLParent: needsSignedStreamURLs
        )
        api.getFiles(parentID: fileID, query: query) { result in
            switch result {
            case .success(let data):
                guard let file = data.parent else {
                    return completion(false, CastError(reason: .fileNotFound))
                }
                castFile = file
                receiver = self.sessionReceiver(currentCastSession)

                if file.needConvert && file.metaData?.codec != "h264" {
                    return completion(false, CastError(reason: .fileNeedsConvert))
                }

                let metadata = self.createGCKMediaMetadata(for: file)
                let mediaLoadOptions = self.createGCKMediaLoadOptions(for: file)

                self.createGCKMediaInformation(for: file, receiver: receiver, metadata: metadata, mediaLoadOptions: mediaLoadOptions) { (mediaInformation, error) in
                    guard let mediaInformation = mediaInformation else {
                        requestError = error as? PutioSDKError
                        return completion(false, CastError(reason: .missingMetadata))
                    }

                    self.castingFileId = fileID
                    self.timer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(self.saveVideoTime), userInfo: nil, repeats: true)

                    if let load = currentCastSession?.remoteMediaClient?.loadMedia(mediaInformation, with: mediaLoadOptions) {
                        load.delegate = self
                        self.replaceReceiverLoad(with: receiver == .putio ? ReceiverLoad(fileID: file.id, request: load) : nil)
                        self.playbackTracker.loadStarted(load, playback: self.castPlayback(for: file, receiver: receiver), fileID: file.id, session: session)
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

    private func castPlayback(for file: PutioFile?, receiver: CastReceiver) -> AnalyticsEvent.Playback {
        let streamMethod: AnalyticsEvent.StreamMethod
        if receiver == .putio || userConfig?.chromecastPlaybackType == "hls" {
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

    private func attachReceiverChannel(to session: GCKCastSession) {
        detachReceiverChannel(from: session)
        guard sessionReceiver(session) == .putio else { return }
        let channel = PutioCastChannel(namespace: CastReceiver.namespace)
        channel.onStatus = { [weak self] status in self?.receiverStatusChanged(status) }
        session.add(channel)
        receiverChannel = channel
    }

    private func detachReceiverChannel(from session: GCKCastSession) {
        guard let receiverChannel else { return }
        session.remove(receiverChannel)
        self.receiverChannel = nil
    }

    private func receiverStatusChanged(_ status: PutioReceiverStatus) {
        guard let load = receiverLoad else { return }
        switch status {
        case .loading(.some(load.fileID)), .loaded(.some(load.fileID)):
            receiverLoad?.accepted = true
        case .failed(.some(load.fileID), let reason) where load.accepted:
            reportReceiverFailure(fileID: load.fileID, reason: reason)
        default:
            break
        }
    }

    private func receiverMediaFailed(_ mediaStatus: GCKMediaStatus) {
        guard let load = receiverLoad else { return }
        let contentID = mediaStatus.mediaInformation?.contentID
        if contentID == String(load.fileID), mediaStatus.mediaSessionID != 0 {
            receiverLoad?.mediaSessionID = mediaStatus.mediaSessionID
        }
        let isThisLoad = contentID == String(load.fileID)
            || (contentID == nil && mediaStatus.mediaSessionID != 0 && mediaStatus.mediaSessionID == receiverLoad?.mediaSessionID)
        guard isThisLoad else { return }
        if [.playing, .paused, .buffering].contains(mediaStatus.playerState) {
            receiverLoad?.fallback?.cancel()
            receiverLoad?.fallback = nil
            return
        }
        guard mediaStatus.playerState == .idle, mediaStatus.idleReason == .error else { return }
        receiverChannel?.requestStatus()
        guard load.fallback == nil else { return }
        let fallback = DispatchWorkItem { [weak self] in
            self?.reportReceiverFailure(fileID: load.fileID, reason: .streamFailed)
        }
        receiverLoad?.fallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: fallback)
    }

    private func reportReceiverFailure(fileID: Int, reason: PutioReceiverStatus.Reason) {
        guard receiverLoad?.fileID == fileID else { return }
        playbackTracker.receiverFailed(fileID: fileID, reason: reason)
        endReceiverLoadWithError()
    }

    private func receiverLoadFailed(_ request: GCKRequest) {
        guard receiverLoad?.request === request else { return }
        endReceiverLoadWithError()
    }

    private func endReceiverLoadWithError() {
        clearReceiverLoad()
        timer?.invalidate()
        presentCastingError()
    }

    private func replaceReceiverLoad(with next: ReceiverLoad?) {
        flushPendingReceiverFailure()
        receiverLoad = next
    }

    private func flushPendingReceiverFailure() {
        if let pending = receiverLoad, pending.fallback != nil {
            playbackTracker.receiverFailed(fileID: pending.fileID, reason: .streamFailed)
        }
        clearReceiverLoad()
    }

    private func clearReceiverLoad() {
        receiverLoad?.fallback?.cancel()
        receiverLoad = nil
    }

    private func presentCastingError() {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        guard var top = windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        guard !(top is UIAlertController) else { return }
        top.present(UIAlertController.castingError(), animated: true)
    }
}

extension UIAlertController {
    static func castingError() -> UIAlertController {
        let alertController = UIAlertController(
            title: NSLocalizedString("Casting Error", comment: ""),
            message: NSLocalizedString("An error occurred while trying to cast this file. Please try again.", comment: ""),
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .destructive, handler: nil))
        return alertController
    }
}

extension ChromecastManager: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        attachReceiverChannel(to: session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        attachReceiverChannel(to: session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        if timer != nil { timer?.invalidate() }
        playbackTracker.sessionEnded()
        if let error = error { logError(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        if timer != nil { timer?.invalidate() }
        detachReceiverChannel(from: session)
        flushPendingReceiverFailure()
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
        if let mediaStatus = client.mediaStatus { receiverMediaFailed(mediaStatus) }
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        playbackTracker.loadFailed(request, error: error)
        receiverLoadFailed(request)
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
        receiverMediaFailed(mediaStatus)
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
        let fileID: Int
        let session: Int
    }

    private struct Playing {
        let load: Load
        let startedAt: Date
        var mediaSessionID: Int?
        var played = false
    }

    private let capture: (AnalyticsEvent, Int) -> Void
    private let report: (SentryTelemetry.PlaybackFailure, Error?, Int) -> Void
    private let now: () -> Date
    private var pending: (request: AnyObject, load: Load)?
    private var playing: Playing?
    private var errored: Playing?

    init(
        capture: @escaping (AnalyticsEvent, Int) -> Void = ProductAnalytics.capture(_:startedIn:),
        report: @escaping (SentryTelemetry.PlaybackFailure, Error?, Int) -> Void = SentryTelemetry.capture(_:error:startedIn:),
        now: @escaping () -> Date = Date.init
    ) {
        self.capture = capture
        self.report = report
        self.now = now
    }

    func loadStarted(_ request: AnyObject, playback: AnalyticsEvent.Playback, fileID: Int, session: Int) {
        pending = (request, Load(playback: playback, fileID: fileID, session: session))
        playing = nil
        errored = nil
    }

    func loadCompleted(_ request: AnyObject, status: Status?) -> Bool {
        guard let load = takePending(request) else { return false }
        capture(.playbackStarted(load.playback), load.session)
        playing = Playing(load: load, startedAt: now(), mediaSessionID: status?.activeMediaSessionID, played: status?.playerState == .playing)
        return true
    }

    func loadFailed(_ request: AnyObject, error: GCKError) {
        guard let load = takePending(request) else { return }
        capture(.playbackFailed(load.playback, .init(error)), load.session)
        report(.init(playback: load.playback, fileID: load.fileID, started: false), error, load.session)
    }

    func loadAborted(_ request: AnyObject) {
        _ = takePending(request)
    }

    func receiverFailed(fileID: Int, reason: PutioReceiverStatus.Reason) {
        let failed: (load: Load, started: Bool)
        if let pending, pending.load.fileID == fileID {
            self.pending = nil
            failed = (pending.load, false)
        } else if let current = playing ?? errored, current.load.fileID == fileID {
            playing = nil
            errored = nil
            failed = (current.load, current.played)
        } else {
            return
        }
        capture(.playbackFailed(failed.load.playback, reason.playbackError), failed.load.session)
        report(.init(playback: failed.load.playback, fileID: failed.load.fileID, started: failed.started), reason, failed.load.session)
    }

    func update(_ status: Status) {
        guard let current = playing else { return }
        if status.playerState == .playing { playing?.played = true }
        guard let mediaSessionID = current.mediaSessionID else {
            playing?.mediaSessionID = status.activeMediaSessionID
            return
        }
        guard status.playerState == .idle, status.mediaSessionID == mediaSessionID else { return }
        playing = nil
        if status.idleReason == .error { errored = current }
        guard status.idleReason == .finished else { return }
        capture(.playbackEnded(current.load.playback, .init(seconds: now().timeIntervalSince(current.startedAt))), current.load.session)
    }

    func sessionEnded() {
        playing = nil
        errored = nil
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

extension PutioSubtitle {
    static func trackLabels(for subtitles: [PutioSubtitle]) -> [String] {
        var counts: [String: Int] = [:]
        return subtitles.map { subtitle in
            let label = subtitle.baseTrackLabel
            let count = counts[label, default: 0] + 1
            counts[label] = count
            return count == 1 ? label : "\(label) (\(count))"
        }
    }

    private var baseTrackLabel: String {
        let language = languageCode == "und" ? NSLocalizedString("Unknown", comment: "Cast subtitle track language when the subtitle has no language code.") : self.language
        guard !name.isEmpty else { return language }
        return "\(language) - \(Self.removingExtension(name).replacingOccurrences(of: "\"", with: "'"))"
    }

    private static func removingExtension(_ name: String) -> String {
        let fileStart = name.lastIndex(of: "/").map(name.index(after:)) ?? name.startIndex
        guard let dot = name.lastIndex(of: "."), dot > fileStart,
              name[fileStart..<dot].contains(where: { $0 != "." }) else { return name }
        return String(name[..<dot])
    }

    var castableURL: URL? {
        guard let format = format?.lowercased(), ["srt", "webvtt"].contains(format) else { return nil }
        return URL(string: url)?.appending(queryItems: [URLQueryItem(name: "format", value: "webvtt")])
    }
}
