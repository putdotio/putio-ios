import XCTest
@testable import Putio
import PutioSDK

private struct MockPutioError: PutioErrorLocalizableInput {
    let localizerType: PutioSDKErrorType
}

final class APIErrorLocalizerTests: XCTestCase {
    func testNetworkErrorsUseDefaultLocalizedCopy() {
        let localizedError = api.localizeError(error: MockPutioError(localizerType: .networkError))

        XCTAssertEqual(localizedError.message, "Network error")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please check your internet connection and try again.")
    }

    func testStatusCodeLocalizersOverrideDefaultMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 401, errorType: "unauthorized")),
            localizers: [
                APIErrorLocalizer(matcher: .statusCode(401)) { _ in
                    PutioLocalizedError(
                        message: "Session expired",
                        recoverySuggestion: .instruction(description: "Please sign in again.")
                    )
                }
            ]
        )

        XCTAssertEqual(localizedError.message, "Session expired")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please sign in again.")
    }

    func testErrorTypeLocalizersOverrideDefaultMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 429, errorType: "rate_limited")),
            localizers: [
                APIErrorLocalizer(matcher: .errorType("rate_limited")) { _ in
                    PutioLocalizedError(
                        message: "Slow down",
                        recoverySuggestion: .instruction(description: "Please wait a moment before trying again.")
                    )
                }
            ]
        )

        XCTAssertEqual(localizedError.message, "Slow down")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please wait a moment before trying again.")
    }

    func testUnknownHttpErrorsFallBackToGenericMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .httpError(statusCode: 500, errorType: "server_error"))
        )

        XCTAssertEqual(localizedError.message, "Something went wrong")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please try again later")
    }

    func testUnknownErrorsFallBackToGenericMessage() {
        let localizedError = api.localizeError(
            error: MockPutioError(localizerType: .unknownError)
        )

        XCTAssertEqual(localizedError.message, "Something went wrong")
        XCTAssertEqual(localizedError.recoverySuggestion.description, "Please try again later")
    }
}
