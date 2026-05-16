import SwiftUI
import AVKit

/// Bridges `AVPlayerViewController` so SwiftUI can host the system player. The
/// platform owns chrome (transport controls, Info, subtitles/audio panel, focus),
/// which is the entire tvOS-side parity contract from the spec.
struct SystemPlayerView: UIViewControllerRepresentable {
    let url: URL
    let startAt: Int
    var onProgress: ((Int) -> Void)? = nil
    var onFinish: ((Int) -> Void)? = nil
    var onError: ((Error) -> Void)? = nil

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false

        if startAt > 0 {
            let time = CMTime(seconds: Double(startAt), preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        context.coordinator.attach(player: player, item: item)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onFinish: onFinish, onError: onError)
    }

    @MainActor
    final class Coordinator: NSObject {
        let onProgress: ((Int) -> Void)?
        let onFinish: ((Int) -> Void)?
        let onError: ((Error) -> Void)?

        private weak var player: AVPlayer?
        private weak var item: AVPlayerItem?
        private var timeObserver: Any?

        init(onProgress: ((Int) -> Void)?, onFinish: ((Int) -> Void)?, onError: ((Error) -> Void)?) {
            self.onProgress = onProgress
            self.onFinish = onFinish
            self.onError = onError
        }

        func attach(player: AVPlayer, item: AVPlayerItem) {
            self.player = player
            self.item = item

            let interval = CMTime(seconds: 5, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let seconds = Int(CMTimeGetSeconds(time))
                if seconds > 0 { self.onProgress?(seconds) }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playbackDidFinish(_:)),
                name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playbackFailed(_:)),
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: item
            )
        }

        deinit {
            if let observer = timeObserver { player?.removeTimeObserver(observer) }
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor @objc private func playbackDidFinish(_ notification: Notification) {
            let seconds = Int(CMTimeGetSeconds(item?.currentTime() ?? .zero))
            onFinish?(seconds)
        }

        @MainActor @objc private func playbackFailed(_ notification: Notification) {
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                onError?(error)
            }
        }
    }
}
