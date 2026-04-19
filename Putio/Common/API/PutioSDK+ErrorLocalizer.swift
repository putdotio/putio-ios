import Foundation
import PutioSDK

struct PutioLocalizedErrorRecoveryActionTrigger {
    let label: String
    let callback: () -> Void
}

enum PutioLocalizedErrorRecoverySuggestion {
    case instruction(description: String)
    case action(description: String, trigger: PutioLocalizedErrorRecoveryActionTrigger)

    var description: String {
        switch self {
        case .instruction(let description):
            return description

        case .action(let description, _):
            return description
        }
    }

    var trigger: PutioLocalizedErrorRecoveryActionTrigger? {
        switch self {
        case .instruction:
            return nil
        case .action(_, let trigger):
            return trigger
        }
    }
}

struct PutioLocalizedError {
    let message: String
    let recoverySuggestion: PutioLocalizedErrorRecoverySuggestion
    let underlyingError: Error
}

protocol PutioErrorLocalizableInput: Error {
    var localizerType: PutioSDKErrorType { get }
    var localizerMessage: String { get }
}

extension PutioSDKError: PutioErrorLocalizableInput {
    var localizerType: PutioSDKErrorType { type }
    var localizerMessage: String { message }
}

struct APIErrorLocalizer {
    enum APIErrorLocalizerMatcher {
        case statusCode(_ code: Int)
        case errorType(_ type: String)
        case unknown
    }

    let matcher: APIErrorLocalizer.APIErrorLocalizerMatcher
    let localize: (_ error: PutioErrorLocalizableInput) -> PutioLocalizedError
}

let unknownErrorLocalizer = APIErrorLocalizer(
    matcher: .unknown,
    localize: { error in
        return PutioLocalizedError(
            message: "Something went wrong",
            recoverySuggestion: .instruction(description: "Please try again later"),
            underlyingError: error
        )
    }
)

let networkErrorLocalizer = APIErrorLocalizer(
    matcher: .statusCode(0),
    localize: { error in
        return PutioLocalizedError(
            message: "Network error",
            recoverySuggestion: .instruction(description: "Please check your internet connection and try again."),
            underlyingError: error
        )
    }
)

extension PutioSDK {
    func localizeError(error: PutioErrorLocalizableInput, localizers: [APIErrorLocalizer] = []) -> PutioLocalizedError {
        switch error.localizerType {
        case .httpError(let statusCode, let errorType):
            let byStatusCode = localizers.first { localizer in
                switch localizer.matcher {
                case .statusCode(let statusCodeToMatch):
                    return statusCode == statusCodeToMatch

                default:
                    return false
                }
            }

            if let byStatusCode = byStatusCode {
                return byStatusCode.localize(error)
            }

            let byErrorType = localizers.first { localizer in
                switch localizer.matcher {
                case .errorType(let errorTypeToMatch):
                    return errorType == errorTypeToMatch

                default:
                    return false
                }
            }

            if let byErrorType = byErrorType {
                return byErrorType.localize(error)
            }

            return unknownErrorLocalizer.localize(error)

        case .networkError:
            return networkErrorLocalizer.localize(error)

        case .unknownError:
            return unknownErrorLocalizer.localize(error)
        }
    }
}
