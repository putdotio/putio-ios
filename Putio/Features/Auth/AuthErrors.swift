import Foundation
import PutioSDK

struct AuthErrors {
    static func localizeLoginError(error: PutioSDKError) -> PutioLocalizedError {
        return api.localizeError(error: error, localizers: [
            APIErrorLocalizer(matcher: .statusCode(401), localize: { error in
                return PutioLocalizedError(
                    message: "Invalid username or password",
                    recoverySuggestion: .instruction(description: "Please check your credentials and try again."),
                    underlyingError: error
                )
            })
        ])
    }

    static func localizeTwoFactorAuthError(error: PutioSDKError) -> PutioLocalizedError {
        let invalidCodeErrorMessage = "The code you entered is invalid"
        let invalidCodeErrorRecoverySuggestion: PutioLocalizedErrorRecoverySuggestion = .instruction(description: "Please check your code and try again.")

        return api.localizeError(error: error, localizers: [
            APIErrorLocalizer(matcher: .errorType("invalid_code"), localize: { error in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion,
                    underlyingError: error
                )
            }),

            APIErrorLocalizer(matcher: .errorType("INVALID_VALUE"), localize: { error in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion,
                    underlyingError: error
                )
            }),

            APIErrorLocalizer(matcher: .errorType("code_not_found"), localize: { error in
                return PutioLocalizedError(
                    message: invalidCodeErrorMessage,
                    recoverySuggestion: invalidCodeErrorRecoverySuggestion,
                    underlyingError: error
                )
            })
        ])
    }
}
