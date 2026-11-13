import Foundation
import UIKit
import AVKit

class MediaPlaybackManager {
    static let sharedInstance = MediaPlaybackManager()

    func play(
        _ media: MediaPlayerItem,
        sourceViewController: UIViewController,
        onLocalFileFailure: (() -> Void)? = nil
    ) {
        ProductAnalytics.capture(.screenViewed(.player))
        switch media.fileType {
        case .audio:
            self.playAudio(media, sourceViewController)
        case .video:
            self.playVideo(media, sourceViewController, onLocalFileFailure: onLocalFileFailure)
        }
    }

    private func playVideo(
        _ video: MediaPlayerItem,
        _ sourceViewController: UIViewController,
        onLocalFileFailure: (() -> Void)?
    ) {
        let videoPlayerVC = VideoPlayerViewController()

        videoPlayerVC.item = video
        videoPlayerVC.onLocalFileFailure = onLocalFileFailure
        videoPlayerVC.player = AVPlayer(url: video.url)

        if (sourceViewController as? AVPlayerViewControllerDelegate) != nil {
            videoPlayerVC.delegate = sourceViewController as? AVPlayerViewControllerDelegate
        }

        sourceViewController.present(videoPlayerVC, animated: true)
    }

    private func playAudio(_ audio: MediaPlayerItem, _ sourceViewController: UIViewController) {
        let audioPlayerNC = UIStoryboard(name: "MediaPlayers", bundle: nil)
            .instantiateViewController(withIdentifier: "AudioPlayerNC") as! UINavigationController

        let audioPlayerVC = audioPlayerNC.viewControllers[0] as! AudioPlayerViewController

        audioPlayerNC.modalPresentationStyle = .fullScreen
        audioPlayerVC.mediaItems = [audio]
        sourceViewController.present(audioPlayerNC, animated: true)
    }
}
