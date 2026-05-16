import Foundation
import PutioSDK

/// Top-level state machine for the player flow:
///
/// idle -> preparing -> [resumePrompt | converting | unsupported | playing]
///                                                                 |
///                                                              finished
enum PlaybackState: Equatable {
    case idle
    case preparing(fileID: Int)
    case resumePrompt(file: PutioFile, source: PlaybackSourceResolver.Source, resumeAt: Int)
    case converting(file: PutioFile, progress: Float)
    case unsupported(file: PutioFile)
    case playing(file: PutioFile, source: PlaybackSourceResolver.Source, startAt: Int)
    case finished(file: PutioFile, durationSeconds: Int)
    case failed(LocalizedFailure)

    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case let (.preparing(a), .preparing(b)): return a == b
        case let (.resumePrompt(a, b, c), .resumePrompt(d, e, f)):
            return a.id == d.id && b == e && c == f
        case let (.converting(a, b), .converting(c, d)):
            return a.id == c.id && b == d
        case let (.unsupported(a), .unsupported(b)): return a.id == b.id
        case let (.playing(a, b, c), .playing(d, e, f)):
            return a.id == d.id && b == e && c == f
        case let (.finished(a, b), .finished(c, d)): return a.id == c.id && b == d
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}
