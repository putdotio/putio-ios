import XCTest
@testable import Putio
import PutioSDK

private struct MockPutioError: PutioErrorLocalizableInput {
    let localizerType: PutioSDKErrorType
    let localizerMessage: String
}

final class APIErrorLocalizerTests: XCTestCase {
    func testNetworkErrorsUseDefaultLocalizedCopy() {
        let localizedError = api.localizeError(error: MockPutioError(localizerType: .networkError, localizerMessage: "offline"))

        XCTAssertEqual(localizedError.message, "Network error")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please check your internet connection and try again.")
    }

    func testStatusCodeLocalizersOverrideDefaultMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 401, errorType: "unauthorized"), localizerMessage: "Unauthorized"),
            localizers: [
                APIErrorLocalizer(matcher: .statusCode(401)) { error in
                    PutioLocalizedError(
                        message: "Session expired",
                        recoverySuggestion: .instruction(description: "Please sign in again."),
                        underlyingError: error
                    )
                }
            ]
        )

        XCTAssertEqual(localizedError.message, "Session expired")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please sign in again.")
    }

    func testErrorTypeLocalizersOverrideDefaultMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 429, errorType: "rate_limited"), localizerMessage: "Too many requests"),
            localizers: [
                APIErrorLocalizer(matcher: .errorType("rate_limited")) { error in
                    PutioLocalizedError(
                        message: "Slow down",
                        recoverySuggestion: .instruction(description: "Please wait a moment before trying again."),
                        underlyingError: error
                    )
                }
            ]
        )

        XCTAssertEqual(localizedError.message, "Slow down")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please wait a moment before trying again.")
    }

    func testUnknownHttpErrorsFallBackToGenericMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 500, errorType: "server_error"), localizerMessage: "Server exploded")
        )

        XCTAssertEqual(localizedError.message, "Something went wrong")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please try again later")
    }

    func testUnknownErrorsFallBackToGenericMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .unknownError, localizerMessage: "Mystery failure")
        )

        XCTAssertEqual(localizedError.message, "Something went wrong")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please try again later")
    }
}
