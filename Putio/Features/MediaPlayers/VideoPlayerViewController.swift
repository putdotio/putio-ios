import UIKit
import AVKit
import AVFoundation
import RealmSwift
import PutioSDK

private struct VideoPlaybackPositionEntry: Codable {
    let position: Int
    let updatedAt: Date
    let lastConfirmedRemotePosition: Int?
    let lastConfirmedRemoteAt: Date?

    var hasPendingRemoteConfirmation: Bool {
        guard let lastConfirmedRemotePosition = lastConfirmedRemotePosition,
            let lastConfirmedRemoteAt = lastConfirmedRemoteAt else {
                return true
        }

        return position != lastConfirmedRemotePosition || updatedAt > lastConfirmedRemoteAt
    }
}

private final class VideoPlaybackPositionStore {
    static let shared = VideoPlaybackPositionStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "putio.video-playback-position."

    func entry(for fileID: Int) -> VideoPlaybackPositionEntry? {
        guard let data = userDefaults.data(forKey: key(for: fileID)) else { return nil }
        return try? decoder.decode(VideoPlaybackPositionEntry.self, from: data)
    }

    @discardableResult
    func saveLocalPosition(for fileID: Int, position: Int, at updatedAt: Date = Date()) -> VideoPlaybackPositionEntry {
        let existingEntry = entry(for: fileID)
        let entry = VideoPlaybackPositionEntry(
            position: position,
            updatedAt: updatedAt,
            lastConfirmedRemotePosition: existingEntry?.lastConfirmedRemotePosition,
            lastConfirmedRemoteAt: existingEntry?.lastConfirmedRemoteAt
        )

        persist(entry, for: fileID)
        return entry
    }

    func saveRemoteSnapshot(for fileID: Int, position: Int, observedAt: Date = Date()) {
        persist(
            VideoPlaybackPositionEntry(
                position: position,
                updatedAt: observedAt,
                lastConfirmedRemotePosition: position,
                lastConfirmedRemoteAt: observedAt
            ),
            for: fileID
        )
    }

    private func persist(_ entry: VideoPlaybackPositionEntry, for fileID: Int) {
        guard let data = try? encoder.encode(entry) else { return }
        userDefaults.set(data, forKey: key(for: fileID))
    }

    private func key(for fileID: Int) -> String {
        return "\(keyPrefix)\(fileID)"
    }
}

class VideoPlayerViewController: AVPlayerViewController {
    private lazy var realm: Realm? = PutioRealm.open(context: "VideoPlayerViewController.realm")
    var item: MediaPlayerItem!
    private lazy var user: User? = realm?.objects(User.self).first

    var isPlayerSetup: Bool = false
    var isPlayingInPictureOnPictureMode: Bool = false

    private let playbackPositionStore = VideoPlaybackPositionStore.shared
    private var playerTimeObserver: Any?
    private var hasStoppedPlayback = false
    private var hasDisposedPlayer = false

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerLifecycleObservers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setupPlayer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPlayingInPictureOnPictureMode else { return }
            self.disposePlayerIfNeeded(shouldPersistPlaybackPosition: false, shouldSyncRemoteInBackground: false)
        }
    }

    deinit {
        disposePlayerIfNeeded(shouldPersistPlaybackPosition: true, shouldSyncRemoteInBackground: false)
        NotificationCenter.default.removeObserver(self)
    }

    func getInitialVideoTime(completion: @escaping (_ time: Int) -> Void) {
        if item.consumptionType == .offline {
            guard item.startFrom > 0 else { return completion(0) }
            return showStartFromDialog(item.startFrom) { (selectedStartFrom) in completion(selectedStartFrom) }
        }

        if let localEntry = playbackPositionStore.entry(for: item.id),
            localEntry.hasPendingRemoteConfirmation {
            completeInitialVideoTime(localEntry.position, completion: completion)
            refreshRemotePlaybackPosition(localEntry: localEntry)
            return
        }

        let localEntry = playbackPositionStore.entry(for: item.id)

        api.getStartFrom(fileID: item.id) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let startFrom):
                let observedAt = Date()
                let resolvedStartFrom: Int

                if let localEntry = localEntry, localEntry.hasPendingRemoteConfirmation, localEntry.position != startFrom {
                    resolvedStartFrom = localEntry.position
                } else {
                    resolvedStartFrom = startFrom
                    self.playbackPositionStore.saveRemoteSnapshot(for: self.item.id, position: startFrom, observedAt: observedAt)
                }

                self.completeInitialVideoTime(resolvedStartFrom, completion: completion)

            case .failure:
                let fallbackStartFrom = localEntry?.position ?? self.item.startFrom
                self.completeInitialVideoTime(fallbackStartFrom, completion: completion)
            }
        }
    }

    func showStartFromDialog(_ startFrom: Int, completion: @escaping (_ time: Int) -> Void) {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]

        guard let timestamp = formatter.string(from: Double(startFrom)) else { return completion(0) }

        let alert = UIAlertController(
            title: NSLocalizedString("Where would you like to start?", comment: ""),
            message: String(
                format: NSLocalizedString("Last saved timestamp for this video is %@", comment: ""),
                timestamp
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Continue watching", comment: ""), style: .default, handler: { (_) in completion(startFrom) }))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Start from the beginning", comment: ""), style: .default, handler: { (_) in completion(0) }))

        present(alert, animated: true, completion: nil)
    }

    func setupPlayer() {
        if isPlayerSetup { return }

        getInitialVideoTime { (startFrom) in
            self.isPlayerSetup = true
            self.player?.seek(to: CMTimeMakeWithSeconds(Float64(startFrom), preferredTimescale: 600))
            self.registerPlayerTimeObserver()
            self.player?.play()
            self.onPlaybackStarted()
        }
    }

    func getCurrentTimeAndDuration() -> (Int, Int)? {
        guard player?.currentItem?.status == .readyToPlay,
            let currentTime = player?.currentTime().getFiniteSeconds(),
            let duration = player?.currentItem?.duration.getFiniteSeconds() else { return nil }

        return (Int(currentTime), Int(duration))
    }

    @objc func saveVideoTime() {
        persistPlaybackPosition(shouldSyncRemoteInBackground: false)
    }

    func handlePictureInPictureDidStart() {
        isPlayingInPictureOnPictureMode = true
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    func handlePictureInPictureDidStop() {
        isPlayingInPictureOnPictureMode = false
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    private func completeInitialVideoTime(_ startFrom: Int, completion: @escaping (_ time: Int) -> Void) {
        guard startFrom > 0 else { return completion(0) }
        showStartFromDialog(startFrom) { completion($0) }
    }

    private func refreshRemotePlaybackPosition(localEntry: VideoPlaybackPositionEntry) {
        api.getStartFrom(fileID: item.id) { [weak self] result in
            guard let self = self else { return }

            guard case .success(let remoteStartFrom) = result else { return }

            if remoteStartFrom == localEntry.position {
                self.playbackPositionStore.saveRemoteSnapshot(for: self.item.id, position: remoteStartFrom)
            }
        }
    }

    private func persistPlaybackPosition(shouldSyncRemoteInBackground: Bool) {
        guard user?.settings?.rememberVideoTime == true else { return }
        guard let (currentTime, duration) = getCurrentTimeAndDuration() else { return }
        let startFrom = (currentTime >= duration - 10) ? 0 : currentTime

        if item.consumptionType == .online {
            playbackPositionStore.saveLocalPosition(for: item.id, position: startFrom)
            syncRemotePlaybackPosition(startFrom, shouldSyncRemoteInBackground: shouldSyncRemoteInBackground)
            return
        }

        guard let realm = realm,
            let download = realm.object(ofType: Download.self, forPrimaryKey: item.id) else { return }

        _ = PutioRealm.write(realm, context: "VideoPlayerViewController.persistPlaybackPosition") {
            download.startFrom = startFrom
        }
    }

    func onPlaybackStarted() {
        let iftttEvent = PutioIFTTTPlaybackEvent(
            eventType: "playback_started",
            ingredients: PutioIFTTTPlaybackEventIngredients(
                fileId: item.id,
                fileName: item.name,
                fileType: "VIDEO"
            )
        )

        api.sendIFTTTEvent(event: iftttEvent, completion: { _ in })
    }

    private func onPlaybackStoppedIfNeeded() {
        guard !hasStoppedPlayback else { return }
        hasStoppedPlayback = true

        let iftttEvent = PutioIFTTTPlaybackEvent(
            eventType: "playback_stopped",
            ingredients: PutioIFTTTPlaybackEventIngredients(
                fileId: item.id,
                fileName: item.name,
                fileType: "VIDEO"
            )
        )

        api.sendIFTTTEvent(event: iftttEvent, completion: { _ in })
    }

    private func disposePlayerIfNeeded(shouldPersistPlaybackPosition: Bool, shouldSyncRemoteInBackground: Bool) {
        guard !hasDisposedPlayer else { return }
        hasDisposedPlayer = true

        if shouldPersistPlaybackPosition {
            persistPlaybackPosition(shouldSyncRemoteInBackground: shouldSyncRemoteInBackground)
        }

        unregisterPlayerTimeObserver()
        player?.pause()
        onPlaybackStoppedIfNeeded()
    }

    private func registerPlayerTimeObserver() {
        guard playerTimeObserver == nil else { return }

        playerTimeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main,
            using: { [weak self] _ in
                guard let self = self, (self.player?.rate ?? 0) > 0 else { return }
                self.persistPlaybackPosition(shouldSyncRemoteInBackground: false)
        })
    }

    private func unregisterPlayerTimeObserver() {
        guard let playerTimeObserver = playerTimeObserver else { return }
        player?.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
    }

    private func registerLifecycleObservers() {
        let notificationCenter = NotificationCenter.default

        notificationCenter.addObserver(self, selector: #selector(handleApplicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleApplicationWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        notificationCenter.addObserver(self, selector: #selector(handleMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handlePlaybackStalled(_:)), name: .AVPlayerItemPlaybackStalled, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handlePlaybackFailed(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handlePlaybackEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    @objc private func handleApplicationDidEnterBackground() {
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handleApplicationWillTerminate() {
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handleMemoryWarning() {
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let interruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            interruptionType == AVAudioSession.InterruptionType.began.rawValue else { return }

        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handlePlaybackStalled(_ notification: Notification) {
        guard isNotificationForCurrentPlayerItem(notification) else { return }
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handlePlaybackFailed(_ notification: Notification) {
        guard isNotificationForCurrentPlayerItem(notification) else { return }
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    @objc private func handlePlaybackEnded(_ notification: Notification) {
        guard isNotificationForCurrentPlayerItem(notification) else { return }
        persistPlaybackPosition(shouldSyncRemoteInBackground: true)
    }

    private func isNotificationForCurrentPlayerItem(_ notification: Notification) -> Bool {
        guard let notificationPlayerItem = notification.object as? AVPlayerItem else { return false }
        return notificationPlayerItem == player?.currentItem
    }

    private func syncRemotePlaybackPosition(_ startFrom: Int, shouldSyncRemoteInBackground: Bool) {
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

        if shouldSyncRemoteInBackground {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveVideoPlaybackPosition") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        let completion: PutioSDKBoolCompletion = { _ in
            guard backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }

        if startFrom == 0 {
            api.resetStartFrom(fileID: item.id, completion: completion)
        } else {
            api.setStartFrom(fileID: item.id, time: startFrom, completion: completion)
        }
    }
}
