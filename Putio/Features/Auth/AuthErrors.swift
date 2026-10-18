import Foundation
import PutioSDK

struct AuthErrors {
    static func localizeTwoFactorAuthError(error: PutioSDKError) -> PutioLocalizedError {
        let invalidCodeErrorMessage = NSLocalizedString("The code you entered is invalid", comment: "")
        let invalidCodeErrorRecoverySuggestion: PutioLocalizedErrorRecoverySuggestion = .instruction(description: NSLocalizedString("Please check your code and try again.", comment: ""))

        return api.localizeError(error: error, localizers: [
            APIErrorLocalizer(matcher: .errorType("invalid_code"), localize: { _ in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion
                )
            }),

            APIErrorLocalizer(matcher: .errorType("INVALID_VALUE"), localize: { _ in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion
                )
            }),

            APIErrorLocalizer(matcher: .errorType("code_not_found"), localize: { _ in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion
                )
            })
        ])
    }
}
