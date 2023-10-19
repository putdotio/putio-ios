import UIKit
import AVFoundation
import MediaPlayer
import RealmSwift
import SwiftGifOrigin

enum UIState {
    case loading, success, failure
}

class AudioPlayerViewController: UIViewController {
    let realm = try! Realm()

    var user: User = {
        let realm = try! Realm()
        return realm.objects(User.self).first!
    }()

    var mediaItems: [MediaPlayerItem]!
    var nextMediaFinder = NextMediaFinder()

    var player: AVQueuePlayer?
    var timeObservers: [Any?] = []

    var playerQueueObserver: NSKeyValueObservation?
    var playerRateObserver: NSKeyValueObservation?
    var playerTimeControlStatusObserver: NSKeyValueObservation?
    var playerTimeObserver: Any?
    var playerSetStartFromTimeObserver: Any?

    var setStartFromTimer: Timer?
    var setStartFromMap = [Int: Int]()

    var commandCenterTargets: [String: Any] = [:]

    // MARK: Poster UI
    @IBOutlet weak var posterImage: UIImageView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!

    // MARK: Player Controls UI
    @IBOutlet weak var currentTimeLabel: UILabel!
    @IBOutlet weak var durationLabel: UILabel!
    @IBOutlet weak var timeSlider: UISlider!
    @IBOutlet weak var controlRewind: UIButton!
    @IBOutlet weak var controlPlayPause: UIButton!
    @IBOutlet weak var controlFastForward: UIButton!

    // MARK: Next Item UI
    @IBOutlet weak var nextItemLoadingView: UIStackView!
    @IBOutlet weak var nextItemLabel: UILabel!
    @IBOutlet weak var nextItemActionButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        nextMediaFinder.delegate = self
        configureStateMachine(for: .loading)
        setupPlayer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        disposePlayer()
    }

    func setupPlayer() {
        guard let media = mediaItems.first else { return }

        let asset = AVAsset(url: media.url)
        let playerItem = AVPlayerItem.init(asset: asset)

        player = AVQueuePlayer()

        registerPlayerObservers()
        registerPlayerTimeObservers()
        registerRemoteMediaControls()

        player?.insert(playerItem, after: player?.currentItem)
        player?.seek(to: CMTimeMakeWithSeconds(Float64(media.startFrom), 600))
        player?.play()
    }

    func disposePlayer() {
        player?.pause()
        unregisterPlayerObservers()
        unregisterPlayerTimeObservers()
        unRegisterRemoteMediaControls()
    }

    func configureStateMachine(for state: UIState, with item: MediaPlayerItem? = nil) {
        switch state {
        case .loading:
            nextItemLoadingView.isHidden = false
            nextItemLabel.isHidden = true
            nextItemActionButton.isEnabled = false
            nextItemActionButton.tintColor = .gray

        case .success:
            nextItemLabel.text = item?.name
            nextItemLabel.isHidden = false
            nextItemLoadingView.isHidden = true
            nextItemActionButton.isEnabled = true
            nextItemActionButton.tintColor = UIColor.Putio.yellow

        case .failure:
            nextItemLabel.text =  "We couldn't find anything to play"
            nextItemLabel.isHidden = false
            nextItemLoadingView.isHidden = true
            nextItemActionButton.isEnabled = false
            nextItemActionButton.tintColor = .gray
        }
    }

    func configurePlaybackControls(isEnabled: Bool) {
        timeSlider.isEnabled = isEnabled
        controlPlayPause.isEnabled = isEnabled
        controlRewind.isEnabled = isEnabled
        controlFastForward.isEnabled = isEnabled
        nextItemActionButton.isEnabled = isEnabled
    }

    func findMediaItem(by playerItem: AVPlayerItem?) -> MediaPlayerItem? {
        guard let item = playerItem, let currentItemAsset = item.asset as? AVURLAsset else { return nil }
        guard let media = mediaItems.first(where: { $0.url == currentItemAsset.url }) else { return nil }
        return media
    }

    func registerPlayerObservers() {
        playerQueueObserver = player?.observe(\.currentItem, options: [.new], changeHandler: { [weak self] (_, change) in
            guard let currentItem = change.newValue as? AVPlayerItem else { return }
            guard let media = self?.findMediaItem(by: currentItem) else { return }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: media.name,
                MPMediaItemPropertyAssetURL: media.url
            ]

            self?.navigationItem.title = media.name
            self?.nextMediaFinder.findNextMedia(for: media)
        })

        playerTimeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.new, .old], changeHandler: { [weak self] (player, _) in
            switch player.timeControlStatus {
            case .playing:
                self?.controlPlayPause.setImage(UIImage(named: "iconPauseBorder"), for: .normal)
                self?.activityIndicator.isHidden = true
                self?.configurePlaybackControls(isEnabled: true)
                self?.posterImage.loadGif(name: "discoball")
            case .paused:
                self?.controlPlayPause.setImage(UIImage(named: "iconPlayBorder"), for: .normal)
                self?.posterImage.image = UIImage(named: "discoball")
            case .waitingToPlayAtSpecifiedRate:
                self?.posterImage.image = UIImage(named: "discoball")
                self?.activityIndicator.isHidden = false
                self?.configurePlaybackControls(isEnabled: false)
            }
        })
    }

    func unregisterPlayerObservers() {
        playerQueueObserver?.invalidate()
        playerTimeControlStatusObserver?.invalidate()
    }

    func registerPlayerTimeObservers() {
        playerTimeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main,
            using: { [weak self] (_) in
                guard let player = self?.player else { return }

                if player.rate == 1.0 {
                    guard let currentTime = player.currentItem?.currentTime().getFiniteSeconds() else { return }
                    guard let duration = player.currentItem?.duration.getFiniteSeconds() else { return }
                    self?.updateTimeDisplay(currentTime: currentTime, duration: duration)
                }
        })

        playerSetStartFromTimeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 15.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main,
            using: { [weak self] (_) in
                guard let player = self?.player else { return }

                if player.rate == 1.0 {
                    guard let media = self?.findMediaItem(by: player.currentItem) else { return }
                    guard let currentTime = player.currentItem?.currentTime().getFiniteSeconds() else { return }
                    guard let duration = player.currentItem?.duration.getFiniteSeconds() else { return }
                    self?.saveAudioTime(for: media, currentTime: currentTime, duration: duration)
                    self?.updateMPNowPlayingInfo(for: media, currentTime: currentTime, duration: duration)
                }
            }
        )
    }

    func unregisterPlayerTimeObservers() {
        if let timeObserver = playerTimeObserver {
            player?.removeTimeObserver(timeObserver)
        }

        if let setStartFromTimeObserver = playerSetStartFromTimeObserver {
            player?.removeTimeObserver(setStartFromTimeObserver)
        }
    }

    func registerRemoteMediaControls() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenterTargets["togglePlayPause"] = commandCenter.pauseCommand.addTarget { (_) -> MPRemoteCommandHandlerStatus in
            self.onTogglePlayPause()
            return .success
        }

        commandCenterTargets["togglePlayPause"] = commandCenter.playCommand.addTarget { (_) -> MPRemoteCommandHandlerStatus in
            self.onTogglePlayPause()
            return .success
        }

        commandCenterTargets["skipBackward"] = commandCenter.previousTrackCommand.addTarget { (_) -> MPRemoteCommandHandlerStatus in
            self.onRewind()
            return .success
        }

        commandCenterTargets["skipForward"] = commandCenter.nextTrackCommand.addTarget { (_) -> MPRemoteCommandHandlerStatus in
            self.onFastForward()
            return .success
        }

        commandCenterTargets["changePlaybackPosition"] = commandCenter.changePlaybackPositionCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            self.onSeek(to: Float((event as! MPChangePlaybackPositionCommandEvent).positionTime))
            return .success
        }
    }

    func unRegisterRemoteMediaControls() {
        UIApplication.shared.endReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(commandCenterTargets["togglePlayPause"])
        commandCenter.skipBackwardCommand.removeTarget(commandCenterTargets["skipBackward"])
        commandCenter.skipForwardCommand.removeTarget(commandCenterTargets["skipForward"])
        commandCenter.changePlaybackPositionCommand.removeTarget(commandCenterTargets["changePlaybackPosition"])
    }

    func saveAudioTime(for item: MediaPlayerItem, currentTime: Double, duration: Double) {
        guard let userSettings = user.settings, userSettings.rememberVideoTime else { return }

        let startFrom = Int((currentTime >= duration - 15.0) ? 0 : currentTime)

        if let lastStartFrom = setStartFromMap[item.id] {
            if abs(startFrom - lastStartFrom) < 15 { return }
        }

        log.debug("[\(item.id) - \(item.name)] | [\(currentTime) : \(duration)]")

        setStartFromMap[item.id] = startFrom

        if item.consumptionType == .online {
            return api.setStartFrom(fileID: item.id, time: startFrom, completion: { _ in })
        }

        if let download = realm.object(ofType: Download.self, forPrimaryKey: item.id) {
            try! realm.write { download.startFrom = startFrom }
        }
    }

    func onTogglePlayPause() {
        guard let rate = player?.rate else { return }

        switch rate {
        case 1.0:
            player?.pause()
        case 0.0:
            player?.play()
        default:
            log.warning("Unhandled player rate \(rate)")
        }
    }

    func updateMPNowPlayingInfo(for item: MediaPlayerItem, currentTime: Double, duration: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyAssetURL: item.url,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
        ]
    }

    func updateTimeDisplay(currentTime: Double, duration: Double) {
        if !timeSlider.isTracking {
            timeSlider.minimumValue = Float(0)
            timeSlider.value = Float(currentTime)
            timeSlider.maximumValue = Float(duration)
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]

        currentTimeLabel.text = formatter.string(from: currentTime)
        durationLabel.text = formatter.string(from: duration)
    }

    func onRewind() {
        guard let currentTime = player?.currentItem?.currentTime().seconds else { return }
        player?.seek(to: CMTimeMakeWithSeconds(Float64(Int(currentTime) - 15), 600))
    }

    func onFastForward() {
        guard let currentTime = player?.currentItem?.currentTime().seconds else { return }
        player?.seek(to: CMTimeMakeWithSeconds(Float64(Int(currentTime) + 15), 600))
    }

    func onSeek(to: Float) {
        player?.seek(to: CMTimeMakeWithSeconds(Float64(to), 600))
    }

    @IBAction func onTimeSliderValueChanged(_ sender: Any) {
        onSeek(to: timeSlider.value)
    }

    @IBAction func playPauseButtonTapped(_ sender: Any) {
        onTogglePlayPause()
    }

    @IBAction func rewindButtonTapped(_ sender: Any) {
        onRewind()
    }

    @IBAction func fastForwardButtonTapped(_ sender: Any) {
        onFastForward()
    }

    @IBAction func closeButtonTapped(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func nextItemActionButtonTapped(_ sender: Any) {
        player?.advanceToNextItem()
        player?.play()
    }
}

extension AudioPlayerViewController: NextMediaFinderDelegate {
    func didFindNextMedia(nextMedia: MediaPlayerItem) {
        mediaItems.append(nextMedia)
        configureStateMachine(for: .success, with: nextMedia)

        let asset = AVAsset(url: nextMedia.url)
        let playerItem = AVPlayerItem.init(asset: asset)
        player?.insert(playerItem, after: player?.currentItem)
    }

    func didCannotFindNextMedia() {
        configureStateMachine(for: .failure)
    }
}
