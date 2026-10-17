import XCTest
import UIKit
@testable import Putio
@testable import PutioSDK

extension PutioSDKError {
    static func offline(_ path: String) -> PutioSDKError {
        let config = PutioSDKRequestConfig(apiConfig: PutioSDKConfig(clientID: "3001"), url: path, method: .post)
        return PutioSDKError(request: PutioSDKErrorRequestInformation(config: config), error: URLError(.notConnectedToInternet))
    }
}

final class ProductAnalyticsPromptTests: XCTestCase {
    private var writes: [String] = []
    private var settingResults: [Result<Void, PutioSDKError>] = []
    private var answerResults: [Result<Void, PutioSDKError>] = []

    override func setUp() {
        super.setUp()
        writes = []
        settingResults = []
        answerResults = []
    }

    func testAsksOnlyAnAccountWithAnalyticsOffAndNoAnswer() {
        XCTAssertTrue(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: false, promptAnswered: false))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: true, promptAnswered: false))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: false, promptAnswered: true))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: true, promptAnswered: true))
    }

    func testAllowSavesTheSettingThenTheAnswerThenTheLocalCopy() {
        let prompt = makePrompt()

        prompt.allowButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: true", "answer", "local: true"])
        XCTAssertFalse(prompt.isSaving)
        XCTAssertTrue(prompt.errorLabel.isHidden)
    }

    func testDontAllowSavesTheSettingOffThenTheAnswer() {
        let prompt = makePrompt()

        prompt.denyButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: false", "answer", "local: false"])
    }

    func testAFailedSettingWritesNoAnswerAndStaysOpenToRetry() throws {
        settingResults = [.failure(.offline("/account/settings"))]
        let prompt = makePrompt()

        prompt.allowButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: true"])
        XCTAssertFalse(prompt.errorLabel.isHidden)
        XCTAssertEqual(
            prompt.errorLabel.text,
            "\(NSLocalizedString("Network error", comment: ""))\n\(NSLocalizedString("Please check your internet connection and try again.", comment: ""))"
        )
        XCTAssertTrue(prompt.allowButton.isEnabled)
        XCTAssertTrue(prompt.denyButton.isEnabled)
        XCTAssertFalse(prompt.isModalInPresentation)

        prompt.allowButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: true", "setting: true", "answer", "local: true"])
        XCTAssertTrue(prompt.errorLabel.isHidden)
    }

    func testAFailedAnswerShowsTheErrorAndRetriesBothWrites() {
        answerResults = [.failure(.offline("/config/dismissed.product_analytics_prompt"))]
        let prompt = makePrompt()

        prompt.denyButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: false", "answer"])
        XCTAssertFalse(prompt.errorLabel.isHidden)

        prompt.denyButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: false", "answer", "setting: false", "answer", "local: false"])
    }

    func testCannotBeClosedOrAnsweredTwiceWhileSaving() {
        var pendingSetting: ((Result<Void, PutioSDKError>) -> Void)?
        let prompt = ProductAnalyticsPromptViewController(
            saveSetting: { enabled, completion in
                self.writes.append("setting: \(enabled)")
                pendingSetting = completion
            },
            markAnswered: { completion in
                self.writes.append("answer")
                completion(.success(()))
            },
            storeLocally: { self.writes.append("local: \($0)") }
        )
        prompt.loadViewIfNeeded()

        prompt.allowButton.sendActions(for: .touchUpInside)
        prompt.denyButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(prompt.isModalInPresentation)
        XCTAssertFalse(prompt.accessibilityPerformEscape())
        XCTAssertEqual(writes, ["setting: true"])

        pendingSetting?(.success(()))

        XCTAssertFalse(prompt.isModalInPresentation)
        XCTAssertEqual(writes, ["setting: true", "answer", "local: true"])
    }

    func testClosingWithoutAnsweringWritesNothing() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let prompt = makePrompt()

        let presented = expectation(description: "presented")
        root.present(prompt, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        let dismissed = expectation(description: "dismissed")
        root.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)

        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(writes, [])
    }

    private func makePrompt() -> ProductAnalyticsPromptViewController {
        let prompt = ProductAnalyticsPromptViewController(
            saveSetting: { enabled, completion in
                self.writes.append("setting: \(enabled)")
                completion(self.settingResults.isEmpty ? .success(()) : self.settingResults.removeFirst())
            },
            markAnswered: { completion in
                self.writes.append("answer")
                completion(self.answerResults.isEmpty ? .success(()) : self.answerResults.removeFirst())
            },
            storeLocally: { self.writes.append("local: \($0)") }
        )
        prompt.loadViewIfNeeded()
        return prompt
    }
}
