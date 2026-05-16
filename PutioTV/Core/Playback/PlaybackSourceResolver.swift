import Foundation
import PutioSDK

/// HLS-first source resolver. Mirrors the React Native tvOS behaviour:
/// `use-playback-type-config.ts` forces HLS on tvOS regardless of the
/// `video_playback_type` account setting. MP4 is only used as the explicit
/// fallback when HLS isn't available.
enum PlaybackSourceResolver {
    enum Source: Equatable {
        case hls(URL)
        case mp4(URL)
    }

    enum Decision: Equatable {
        case ready(Source)
        case needsConversion
        case unsupported
    }

    static func decide(for file: PutioFile, token: String) -> Decision {
        guard file.type == .video else {
            return .unsupported
        }

        if !file.streamURL.isEmpty || !file.mp4StreamURL.isEmpty {
            // Always prefer HLS on tvOS — same gate as the RN tvOS app.
            let hls = file.getHlsStreamURL(token: token)
            return .ready(.hls(hls))
        }

        if file.needConvert && !file.hasMp4 {
            return .needsConversion
        }

        return .unsupported
    }
}
