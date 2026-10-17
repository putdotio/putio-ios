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
    private var holdsSetting = false
    private var heldSetting: ((Result<Void, PutioSDKError>) -> Void)?

    override func setUp() {
        super.setUp()
        writes = []
        settingResults = []
        answerResults = []
        holdsSetting = false
        heldSetting = nil
    }

    func testAsksOnlyAnAccountWithAnalyticsOffAndNoAnswer() {
        XCTAssertTrue(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: false, promptAnswered: false, opensLaunchLinks: false))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: true, promptAnswered: false, opensLaunchLinks: false))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: false, promptAnswered: true, opensLaunchLinks: false))
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: true, promptAnswered: true, opensLaunchLinks: false))
    }

    func testALaunchThatOpensLinksWaitsForTheNextLaunch() {
        XCTAssertFalse(ProductAnalyticsChoice.shouldAsk(productAnalyticsEnabled: false, promptAnswered: false, opensLaunchLinks: true))
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

    func testAFailedAnswerKeepsTheSavedSettingAndRetriesBothWrites() {
        answerResults = [.failure(.offline("/config/dismissed.product_analytics_prompt"))]
        let prompt = makePrompt()

        prompt.allowButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: true", "answer", "local: true"])
        XCTAssertFalse(prompt.errorLabel.isHidden)

        prompt.allowButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(writes, ["setting: true", "answer", "local: true", "setting: true", "answer", "local: true"])
        XCTAssertTrue(prompt.errorLabel.isHidden)
    }

    func testCannotBeClosedOrAnsweredTwiceWhileSaving() {
        holdsSetting = true
        let prompt = makePrompt()

        prompt.allowButton.sendActions(for: .touchUpInside)
        prompt.denyButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(prompt.isModalInPresentation)
        XCTAssertFalse(prompt.accessibilityPerformEscape())
        XCTAssertEqual(writes, ["setting: true"])

        heldSetting?(.success(()))

        XCTAssertFalse(prompt.isModalInPresentation)
        XCTAssertEqual(writes, ["setting: true", "answer", "local: true"])
    }

    func testAnAnswerSavedWhileThePrivacyPolicyIsOpenClosesBoth() throws {
        holdsSetting = true
        let prompt = makePrompt()
        let root = try presentOnWindow(prompt)
        prompt.allowButton.sendActions(for: .touchUpInside)
        let policyOpened = expectation(description: "policy opened")
        prompt.present(UIViewController(), animated: false) { policyOpened.fulfill() }
        wait(for: [policyOpened], timeout: 5)

        heldSetting?(.success(()))

        let deadline = Date().addingTimeInterval(5)
        while root.presentedViewController != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(root.presentedViewController, "only the policy closed")
        XCTAssertEqual(writes, ["setting: true", "answer", "local: true"])
    }

    func testClosingWithoutAnsweringWritesNothing() throws {
        let prompt = makePrompt()
        let root = try presentOnWindow(prompt)
        let sheet = try XCTUnwrap(prompt.presentationController)

        // What UIKit sends a swipe-down, around the dismissal itself.
        sheet.delegate?.presentationControllerWillDismiss?(sheet)
        let dismissed = expectation(description: "dismissed")
        root.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
        sheet.delegate?.presentationControllerDidDismiss?(sheet)

        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(writes, [])
    }

    private func presentOnWindow(_ prompt: ProductAnalyticsPromptViewController) throws -> UIViewController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }

        let presented = expectation(description: "presented")
        root.present(prompt, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        return root
    }

    private func makePrompt() -> ProductAnalyticsPromptViewController {
        let prompt = ProductAnalyticsPromptViewController(
            saveSetting: { enabled, completion in
                self.writes.append("setting: \(enabled)")
                if self.holdsSetting {
                    self.heldSetting = completion
                    return
                }
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
