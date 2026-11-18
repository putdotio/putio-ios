import Foundation

extension URL {
    func applyingSubtitlePreference(hideSubtitles: Bool) -> URL {
        guard hideSubtitles else { return self }
        return appending(queryItems: [URLQueryItem(name: "max_subtitle_count", value: "0")])
    }
}
