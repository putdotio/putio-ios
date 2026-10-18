import Foundation
import PutioSDK

enum PutioLocalizedErrorRecoverySuggestion {
    case instruction(description: String)

    var description: String {
        switch self {
        case .instruction(let description):
            return description
        }
    }
}

struct PutioLocalizedError {
    let message: String
    let recoverySuggestion: PutioLocalizedErrorRecoverySuggestion
}

protocol PutioErrorLocalizableInput: Error {
    var localizerType: PutioSDKErrorType { get }
}

extension PutioSDKError: PutioErrorLocalizableInput {
    var localizerType: PutioSDKErrorType { type }
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
    localize: { _ in
        return PutioLocalizedError(
            message: NSLocalizedString("Something went wrong", comment: ""),
            recoverySuggestion: .instruction(description: NSLocalizedString("Please try again later", comment: ""))
        )
    }
)

let networkErrorLocalizer = APIErrorLocalizer(
    matcher: .statusCode(0),
    localize: { _ in
        return PutioLocalizedError(
            message: NSLocalizedString("Network error", comment: ""),
            recoverySuggestion: .instruction(description: NSLocalizedString("Please check your internet connection and try again.", comment: ""))
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

        case .decodingError, .unknownError:
            return unknownErrorLocalizer.localize(error)
        }
    }
}
