import UIKit
import AVFoundation
import AVKit
import MediaPlayer
import RealmSwift

enum UIState {
    case loading, success, failure
}

class AudioPlayerViewController: UIViewController {
    static let supportedPlaybackRates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    private lazy var realm: Realm? = PutioRealm.open(context: "AudioPlayerViewController.realm")
    private lazy var user: User? = realm?.objects(User.self).first

    var mediaItems: [MediaPlayerItem]!
    var nextMediaFinder = NextMediaFinder()

    var player: AVQueuePlayer?
    var timeObservers: [Any?] = []
    var playerQueueObserver: NSKeyValueObservation?
    var playerTimeControlStatusObserver: NSKeyValueObservation?
    var playerTimeObserver: Any?
    var playerSetStartFromTimeObserver: Any?
    var setStartFromTimer: Timer?
    var setStartFromMap = [Int: Int]()

    var commandCenterTargets: [String: Any] = [:]
    var queuePlaybackRate: Float = 1
    var posterContentConstraints: [NSLayoutConstraint] = []
    var compactArtworkHeightConstraint: NSLayoutConstraint?
    var nextItemContentConstraints: [NSLayoutConstraint] = []
    var compactNextItemHeightConstraint: NSLayoutConstraint?

    private(set) lazy var routePickerView: AVRoutePickerView = {
        let routePickerView = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        routePickerView.prioritizesVideoDevices = false
        routePickerView.tintColor = UIColor.Putio.Neutral.text
        routePickerView.activeTintColor = UIColor.Putio.Yellow.textSecondary
        routePickerView.accessibilityIdentifier = "audio-output-route-picker"
        return routePickerView
    }()

    private(set) lazy var playbackRateButton: UIButton = {
        let button = UIButton(type: .system)
        button.tintColor = UIColor.Putio.Neutral.textSecondary
        button.setTitleColor(UIColor.Putio.Neutral.textSecondary, for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = NSLocalizedString("Playback speed", comment: "")
        button.accessibilityHint = NSLocalizedString("Applies to this queue", comment: "")
        return button
    }()

    // MARK: Poster UI
    @IBOutlet weak var playerContentView: UIView!
    @IBOutlet weak var posterContainerView: UIView!
    @IBOutlet weak var posterImage: UIImageView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var trackTitleLabel: UILabel!

    // MARK: Player Controls UI
    @IBOutlet weak var currentTimeLabel: UILabel!
    @IBOutlet weak var durationLabel: UILabel!
    @IBOutlet weak var timeSlider: UISlider!
    @IBOutlet weak var controlRewind: UIButton!
    @IBOutlet weak var controlPlayPause: UIButton!
    @IBOutlet weak var controlFastForward: UIButton!
    @IBOutlet weak var playbackInfoStackView: UIStackView!

    // MARK: Next Item UI
    @IBOutlet weak var nextItemContainerView: UIView!
    @IBOutlet weak var nextItemLoadingView: UIStackView!
    @IBOutlet weak var nextItemLabel: UILabel!
    @IBOutlet weak var nextItemActionButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePlayerAppearance()
        let skipSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        controlRewind.setImage(UIImage(systemName: "gobackward.15", withConfiguration: skipSymbolConfiguration), for: .normal)
        controlPlayPause.setImage(PutioIcon.playCircleFill.image(pointSize: 66), for: .normal)
        controlFastForward.setImage(UIImage(systemName: "goforward.15", withConfiguration: skipSymbolConfiguration), for: .normal)
        nextItemActionButton.setImage(PutioIcon.playFill.image(pointSize: 20), for: .normal)
        configurePlaybackRateControl()
        playbackRateButton.titleLabel?.font = currentTimeLabel.font
        nextMediaFinder.delegate = self
        configureStateMachine(for: .loading)
        setupPlayer()
    }

    func configurePlayerAppearance() {
        configureNavigationControls()
        trackTitleLabel.text = mediaItems.first?.name

        posterContainerView.layer.cornerRadius = 20
        posterContainerView.layer.cornerCurve = .continuous
        posterContainerView.layer.borderWidth = 1
        posterContainerView.layer.borderColor = UIColor.Putio.Neutral.border.cgColor
        posterContainerView.clipsToBounds = true
        posterContentConstraints = posterContainerView.constraints
        compactArtworkHeightConstraint = posterContainerView.heightAnchor.constraint(equalToConstant: 0)

        nextItemContainerView.layer.cornerRadius = 16
        nextItemContainerView.layer.cornerCurve = .continuous
        nextItemContainerView.layer.borderWidth = 1
        nextItemContainerView.layer.borderColor = UIColor.Putio.Neutral.border.cgColor
        nextItemContentConstraints = nextItemContainerView.constraints
        compactNextItemHeightConstraint = nextItemContainerView.heightAnchor.constraint(equalToConstant: 0)

        let timeFontSize = UIFont.preferredFont(forTextStyle: .caption1).pointSize
        let timeFont = BrandFont.monoIfAvailable(size: timeFontSize, weight: .medium)
            ?? UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium)
        currentTimeLabel.font = timeFont
        durationLabel.font = timeFont

        controlRewind.tintColor = UIColor.Putio.Neutral.textSecondary
        controlPlayPause.tintColor = UIColor.Putio.Neutral.text
        controlFastForward.tintColor = UIColor.Putio.Neutral.textSecondary
        controlRewind.accessibilityLabel = NSLocalizedString("Rewind 15 seconds", comment: "")
        controlFastForward.accessibilityLabel = NSLocalizedString("Forward 15 seconds", comment: "")
        controlPlayPause.accessibilityLabel = NSLocalizedString("Play", comment: "")
        controlPlayPause.accessibilityIdentifier = "audio-player-play-pause"
        timeSlider.accessibilityLabel = NSLocalizedString("Playback position", comment: "")
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateCompactHeightLayout(isCompact: traitCollection.verticalSizeClass == .compact)
    }

    func updateCompactHeightLayout(isCompact: Bool) {
        guard compactArtworkHeightConstraint?.isActive != isCompact else { return }

        posterContainerView.isHidden = isCompact
        nextItemContainerView.isHidden = isCompact
        trackTitleLabel.numberOfLines = isCompact ? 1 : 2
        if isCompact {
            NSLayoutConstraint.deactivate(posterContentConstraints)
            NSLayoutConstraint.deactivate(nextItemContentConstraints)
            compactArtworkHeightConstraint?.isActive = true
            compactNextItemHeightConstraint?.isActive = true
        } else {
            compactArtworkHeightConstraint?.isActive = false
            compactNextItemHeightConstraint?.isActive = false
            NSLayoutConstraint.activate(posterContentConstraints)
            NSLayoutConstraint.activate(nextItemContentConstraints)
        }
    }

    func configureNavigationControls() {
        navigationItem.title = NSLocalizedString("Now Playing", comment: "")
        navigationItem.leftBarButtonItem?.accessibilityLabel = NSLocalizedString("Close", comment: "")
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: routePickerView)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        disposePlayer()
    }

    func setupPlayer() {
        guard let media = mediaItems.first else { return }

        let asset = AVURLAsset(url: media.url)
        let playerItem = AVPlayerItem.init(asset: asset)

        player = AVQueuePlayer()
        player?.defaultRate = queuePlaybackRate

        registerPlayerObservers()
        registerPlayerTimeObservers()
        registerRemoteMediaControls()

        player?.insert(playerItem, after: player?.currentItem)
        player?.seek(to: CMTimeMakeWithSeconds(Float64(media.startFrom), preferredTimescale: 600))
        playAtQueueRate()
    }

    func disposePlayer() {
        player?.pause()
        unregisterPlayerObservers()
        unregisterPlayerTimeObservers()
        unregisterRemoteMediaControls()
        player = nil
    }

    func configureStateMachine(for state: UIState, with item: MediaPlayerItem? = nil) {
        switch state {
        case .loading:
            nextItemLoadingView.isHidden = false
            nextItemLabel.isHidden = true
            nextItemActionButton.isHidden = true
            nextItemActionButton.isEnabled = false
            nextItemActionButton.tintColor = UIColor.Putio.Neutral.solid

        case .success:
            nextItemLabel.text = item?.name
            nextItemLabel.textColor = UIColor.Putio.Neutral.text
            nextItemLabel.isHidden = false
            nextItemLoadingView.isHidden = true
            nextItemActionButton.isHidden = false
            nextItemActionButton.isEnabled = true
            nextItemActionButton.tintColor = UIColor.Putio.Yellow.textSecondary

        case .failure:
            nextItemLabel.text = NSLocalizedString("Nothing queued", comment: "")
            nextItemLabel.textColor = UIColor.Putio.Neutral.textSecondary
            nextItemLabel.isHidden = false
            nextItemLoadingView.isHidden = true
            nextItemActionButton.isHidden = true
            nextItemActionButton.isEnabled = false
            nextItemActionButton.tintColor = UIColor.Putio.Neutral.solid
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
            guard let currentItem = change.newValue as? AVPlayerItem else {
                self?.refreshNowPlayingInfo()
                return
            }
            guard let media = self?.findMediaItem(by: currentItem) else { return }

            self?.refreshNowPlayingInfo(for: media)

            self?.trackTitleLabel.text = media.name
            self?.nextMediaFinder.findNextMedia(for: media)
        })

        playerTimeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.new, .old], changeHandler: { [weak self] (player, _) in
            switch player.timeControlStatus {
            case .playing:
                self?.controlPlayPause.setImage(PutioIcon.pauseCircleFill.image(pointSize: 66), for: .normal)
                self?.controlPlayPause.accessibilityLabel = NSLocalizedString("Pause", comment: "")
                self?.activityIndicator.isHidden = true
                self?.configurePlaybackControls(isEnabled: true)
                self?.posterImage.image = UIImage(named: "discoball")
            case .paused:
                self?.controlPlayPause.setImage(PutioIcon.playCircleFill.image(pointSize: 66), for: .normal)
                self?.controlPlayPause.accessibilityLabel = NSLocalizedString("Play", comment: "")
                self?.posterImage.image = UIImage(named: "discoball")
            case .waitingToPlayAtSpecifiedRate:
                self?.posterImage.image = UIImage(named: "discoball")
                self?.activityIndicator.isHidden = false
                self?.configurePlaybackControls(isEnabled: false)
            @unknown default:
                log.warning("Unhandled player time control status: \(player.timeControlStatus.rawValue)")
            }
            self?.refreshNowPlayingInfo()
        })
    }

    func unregisterPlayerObservers() {
        playerQueueObserver?.invalidate()
        playerTimeControlStatusObserver?.invalidate()
        playerQueueObserver = nil
        playerTimeControlStatusObserver = nil
    }

    func registerPlayerTimeObservers() {
        playerTimeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main,
            using: { [weak self] (_) in
                guard let player = self?.player else { return }

                if player.rate != 0 {
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

                if player.rate != 0 {
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
        playerTimeObserver = nil
        playerSetStartFromTimeObserver = nil
    }

    func saveAudioTime(for item: MediaPlayerItem, currentTime: Double, duration: Double) {
        guard let userSettings = user?.settings, userSettings.rememberVideoTime else { return }

        let startFrom = Int((currentTime >= duration - 15.0) ? 0 : currentTime)

        if let lastStartFrom = setStartFromMap[item.id] {
            if abs(startFrom - lastStartFrom) < 15 { return }
        }

        log.debug("[\(item.id) - \(item.name)] | [\(currentTime) : \(duration)]")

        setStartFromMap[item.id] = startFrom

        if item.consumptionType == .online {
            return api.setStartFrom(fileID: item.id, time: startFrom, completion: { _ in })
        }

        if let realm = realm,
            let download = realm.object(ofType: Download.self, forPrimaryKey: item.id) {
            _ = PutioRealm.write(realm, context: "AudioPlayerViewController.saveAudioTime") {
                download.startFrom = startFrom
            }
        }
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
        playAtQueueRate()
    }
}

extension AudioPlayerViewController: NextMediaFinderDelegate {
    func didFindNextMedia(nextMedia: MediaPlayerItem) {
        mediaItems.append(nextMedia)
        configureStateMachine(for: .success, with: nextMedia)

        let asset = AVURLAsset(url: nextMedia.url)
        let playerItem = AVPlayerItem.init(asset: asset)
        player?.insert(playerItem, after: player?.currentItem)
    }

    func didCannotFindNextMedia() {
        configureStateMachine(for: .failure)
    }
}
