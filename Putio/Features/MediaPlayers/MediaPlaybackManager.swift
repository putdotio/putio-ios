import Foundation
import UIKit
import AVKit

class MediaPlaybackManager {
    static let sharedInstance = MediaPlaybackManager()

    func play(_ media: MediaPlayerItem, sourceViewController: UIViewController) {
        switch media.fileType {
        case .audio:
            self.playAudio(media, sourceViewController)
        case .video:
            self.playVideo(media, sourceViewController)
        }
    }

    private func playVideo(_ video: MediaPlayerItem, _ sourceViewController: UIViewController) {
        let videoPlayerVC = VideoPlayerViewController()

        videoPlayerVC.item = video
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
