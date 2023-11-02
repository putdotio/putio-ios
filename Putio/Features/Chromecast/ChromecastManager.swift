import Foundation
import GoogleCast
import RealmSwift
import PutioAPI
import Sentry

class ChromecastManager: NSObject {
    static let sharedInstance = ChromecastManager()

    struct CastError {
        var fileID: Int
        var reason: CastErrorReason
    }

    enum CastErrorReason: Int {
        case fileNotFound, fileNeedsConvert, missingMetadata
    }

    var castingFileId: Int?
    var timer: Timer?

    var debug: Bool = false

    var userSettings: UserSettings? = {
        let realm = try! Realm()
        return realm.objects(User.self).first?.settings
    }()

    var userConfig: UserConfig? = {
        let realm = try! Realm()
        return realm.objects(UserConfig.self).first
    }()

    func setup() {
        let discoveryCriteria = GCKDiscoveryCriteria(applicationID: CHROMECAST_RECEIVER_APP_ID)
        let options = GCKCastOptions(discoveryCriteria: discoveryCriteria)

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

        castViews.backgroundColor = UIColor.Putio.background
        castViews.deviceControl.sliderProgressColor = UIColor.Putio.yellow

        castViews.headingTextColor = .white
        castViews.headingTextShadowColor = .clear

        castViews.captionTextColor = .gray
        castViews.captionTextShadowColor = .clear

        castViews.bodyTextColor = .white
        castViews.bodyTextShadowColor = .clear

        castViews.buttonTextColor = UIColor.Putio.yellow
        castViews.buttonTextShadowColor = .clear

        castViews.iconTintColor = .white

        castViews.sliderProgressColor = UIColor.Putio.yellow
        castViews.sliderSecondaryProgressColor = UIColor.Putio.background
        castViews.sliderUnseekableProgressColor = UIColor.Putio.black
        castViews.sliderTooltipBackgroundColor = UIColor.Putio.black

        castViews.mediaControl.backgroundColor = UIColor.Putio.black
        castViews.mediaControl.headingTextFont = .systemFont(ofSize: 18.0)
        castViews.mediaControl.iconTintColor = UIColor.Putio.yellow
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
        metadata.addImage(GCKImage(url: URL(string: file.screenshot)!, width: 640, height: 360))
        return metadata
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
            mediaInfo.contentID = file.getHlsStreamURL(token: api.config.token).absoluteString
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

    func castVideo(fileID: Int, completion: @escaping (_ success: Bool, _ error: CastError?) -> Void) {
        let currentCastSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession

        if timer != nil {
            timer?.invalidate()
        }

        api.getFiles(parentID: fileID) { result in
            switch result {
            case .success(let data):
                let file = data.parent

                if file.needConvert && file.metaData?.codec != "h264" {
                    return completion(false, CastError(fileID: fileID, reason: .fileNeedsConvert))
                }

                let metadata = self.createGCKMediaMetadata(for: file)
                let mediaLoadOptions = self.createGCKMediaLoadOptions(for: file)

                self.createGCKMediaInformation(for: file, metadata: metadata, mediaLoadOptions: mediaLoadOptions) { (mediaInformation, _) in
                    guard let mediaInformation = mediaInformation else {
                        return completion(false, CastError(fileID: fileID, reason: .missingMetadata))
                    }

                    self.castingFileId = fileID
                    self.timer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(self.saveVideoTime), userInfo: nil, repeats: true)

                    currentCastSession?.remoteMediaClient?.loadMedia(mediaInformation, with: mediaLoadOptions)
                    GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()

                    completion(true, nil)
                }

            case .failure:
                completion(false, CastError(fileID: fileID, reason: .fileNotFound))
            }
        }
    }

    @objc private func saveVideoTime() {
        let realm = try! Realm()
        guard let user = realm.objects(User.self).first,
            user.settings != nil,
            user.settings?.rememberVideoTime == true,
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
        if let error = error { logError(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        if timer != nil { timer?.invalidate() }
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

extension ChromecastManager: GCKLoggerDelegate {
    func logMessage(_ message: String, at level: GCKLoggerLevel, fromFunction function: String, location: String) {
        if debug { log.debug("\(function) - \(message)") }
    }
}
