import SwiftUI
import AVKit

/// Bridges `AVPlayerViewController` so SwiftUI can host the system player. The
/// platform owns chrome (transport controls, Info, subtitles/audio panel, focus),
/// which is the entire tvOS-side parity contract from the spec.
struct SystemPlayerView: UIViewControllerRepresentable {
    let url: URL
    let startAt: Int
    var subtitlePreference: SubtitlePreference = .systemDefault
    var onProgress: ((Int) -> Void)? = nil
    var onFinish: ((Int) -> Void)? = nil
    var onError: ((Error) -> Void)? = nil

    /// Mirrors the React Native `dont_autoselect_subtitles` + `hide_subtitles`
    /// account settings, applied once per playback session before AVPlayer's
    /// default media selection kicks in.
    enum SubtitlePreference: Equatable {
        case systemDefault          // let AVPlayer pick (honors user's tvOS Accessibility setting)
        case off                    // explicitly disable the legible track
        case preserveAutoSelection  // do nothing (rely on AVPlayer auto-select for the user's language)

        init(hideSubtitles: Bool, dontAutoSelect: Bool) {
            if hideSubtitles || dontAutoSelect {
                self = .off
            } else {
                self = .systemDefault
            }
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = AVPlayerItem(url: url)
        item.appliesPerFrameHDRDisplayMetadata = true

        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player

        if startAt > 0 {
            let time = CMTime(seconds: Double(startAt), preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        context.coordinator.attach(player: player, item: item, subtitlePreference: subtitlePreference)
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

        func attach(player: AVPlayer, item: AVPlayerItem, subtitlePreference: SubtitlePreference) {
            self.player = player
            self.item = item

            applySubtitlePreference(subtitlePreference, to: item)

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

        private func applySubtitlePreference(_ preference: SubtitlePreference, to item: AVPlayerItem) {
            guard preference != .systemDefault else { return }

            Task { [weak item] in
                guard let item else { return }
                let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
                guard let group else { return }
                await MainActor.run {
                    switch preference {
                    case .off:
                        item.select(nil, in: group)
                    case .preserveAutoSelection, .systemDefault:
                        break
                    }
                }
            }
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
