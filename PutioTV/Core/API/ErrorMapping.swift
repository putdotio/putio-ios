import Foundation
import PutioSDK

/// Plain-value representation of a feature-level failure. Carries enough state
/// for `ErrorState` to render an actionable retry surface.
struct LocalizedFailure: Equatable, Sendable {
    var message: String
    var recovery: String?
    var retry: (@MainActor @Sendable () -> Void)?

    static func == (lhs: LocalizedFailure, rhs: LocalizedFailure) -> Bool {
        lhs.message == rhs.message && lhs.recovery == rhs.recovery
    }
}

enum ErrorMapping {
    static func localize(
        _ error: Error,
        retry: (@MainActor @Sendable () -> Void)? = nil
    ) -> LocalizedFailure {
        if let sdkError = error as? PutioSDKError {
            return mapSDK(sdkError, retry: retry)
        }
        if error is CancellationError {
            return LocalizedFailure(message: "The request was cancelled.", recovery: nil, retry: retry)
        }
        return LocalizedFailure(
            message: "Something went wrong.",
            recovery: error.localizedDescription,
            retry: retry
        )
    }

    private static func mapSDK(_ error: PutioSDKError, retry: (@MainActor @Sendable () -> Void)?) -> LocalizedFailure {
        if error.isNetworkFailure {
            return LocalizedFailure(
                message: "Can't reach put.io right now.",
                recovery: "Check your network connection and try again.",
                retry: retry
            )
        }

        if let status = error.statusCode {
            return LocalizedFailure(
                message: messageForStatus(status),
                recovery: error.recoverySuggestion ?? "Please try again.",
                retry: retry
            )
        }

        if error.isDecodingFailure {
            return LocalizedFailure(
                message: "put.io responded in an unexpected way.",
                recovery: "Try again. We'll fix this on our end if it keeps happening.",
                retry: retry
            )
        }

        return LocalizedFailure(
            message: "Something went wrong.",
            recovery: error.errorDescription ?? error.localizedDescription,
            retry: retry
        )
    }

    private static func messageForStatus(_ status: Int) -> String {
        switch status {
        case 401, 403: return "Your put.io session is no longer valid."
        case 404: return "Code expired."
        case 429: return "Too many requests — wait a moment and try again."
        case 500..<600: return "put.io is having a moment. We're on it."
        default: return "put.io rejected the request."
        }
    }
}
