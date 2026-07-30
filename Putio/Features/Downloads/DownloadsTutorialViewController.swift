import UIKit
import AVKit

class DownloadsTutorialViewController: UIViewController {
    // Far enough in that the recording shows its loaded file list, not a spinner.
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

        // Hold one frame rather than let the capture race playback. The seek is
        // asynchronous, so "parked" is only reported once the frame is on
        // screen and the walk has something to wait for.
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
