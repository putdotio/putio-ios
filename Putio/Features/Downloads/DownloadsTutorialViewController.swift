import UIKit
import AVKit

class DownloadsTutorialViewController: UIViewController {
    // Where the clip is parked for snapshot captures: far enough in that the
    // recording shows its loaded file list rather than a spinner.
    private static let snapshotFrameSeconds = 2.0

    @IBOutlet weak var videoContainerView: UIView!
    var player: AVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "putio-downloads-tutorial"
        view.accessibilityValue = "loading"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let path = Bundle.main.path(forResource: "downloadsTutorial", ofType: "mov") else {
            return
        }
        player = AVPlayer(url: URL(fileURLWithPath: path))
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = videoContainerView.bounds
        videoContainerView.layer.addSublayer(playerLayer)

        // A playing clip makes the screenshot depend on when the capture lands,
        // so the e2e walk holds one frame instead of racing playback. The seek
        // is asynchronous: report "parked" only once the frame is on screen, so
        // the walk waits for it rather than capturing mid-seek.
        guard PutioE2EEnvironment.isMockAPIEnabled == false else {
            let frame = CMTime(seconds: Self.snapshotFrameSeconds, preferredTimescale: 600)
            player?.seek(to: frame, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished else { return }

                DispatchQueue.main.async {
                    self?.view.accessibilityValue = "parked"
                }
            }
            return
        }

        player?.play()
        view.accessibilityValue = "playing"
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    @IBAction func dismissButtonTapped(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
}
