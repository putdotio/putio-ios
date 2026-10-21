import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class ProductAnalyticsPromptTests: XCTestCase {
  func testConfigReadsTheAnswerAndCountsAnUnreadableValueAsAnswered() throws {
    let cases: [(String, Bool)] = [
      (#"{}"#, false),
      (#"{"dismissed.product_analytics_prompt":null}"#, false),
      (#"{"dismissed.product_analytics_prompt":false}"#, false),
      (#"{"dismissed.product_analytics_prompt":true}"#, true),
      (#"{"dismissed.product_analytics_prompt":"yes"}"#, true),
      (#"{"dismissed":{"product_analytics_prompt":true}}"#, false),
    ]
    for (json, answered) in cases {
      let config = try JSONDecoder().decode(PutioAppConfig.self, from: Data(json.utf8))
      XCTAssertEqual(config.productAnalyticsPromptAnswered, answered, json)
    }
  }

  func testAsksOnlyAnUnansweredAccountWithAnalyticsOffOnALaunchWithoutLinks() {
    XCTAssertTrue(
      PutioProductAnalyticsPrompt.shouldAsk(
        productAnalyticsEnabled: false, promptAnswered: false, opensLaunchLink: false))
    XCTAssertFalse(
      PutioProductAnalyticsPrompt.shouldAsk(
        productAnalyticsEnabled: true, promptAnswered: false, opensLaunchLink: false))
    XCTAssertFalse(
      PutioProductAnalyticsPrompt.shouldAsk(
        productAnalyticsEnabled: false, promptAnswered: true, opensLaunchLink: false))
    XCTAssertFalse(
      PutioProductAnalyticsPrompt.shouldAsk(
        productAnalyticsEnabled: false, promptAnswered: false, opensLaunchLink: true))
  }

  func testAnswerSavesTheSettingBeforeTheAnswer() async {
    var calls: [String] = []
    let model = model(
      saveSetting: { calls.append("setting=\($0)") },
      markAnswered: { calls.append("answered") })

    await model.answer(false)

    XCTAssertEqual(calls, ["setting=false", "answered"])
    XCTAssertTrue(model.isAnswered)
    XCTAssertNil(model.failure)
    await model.answer(true)
    XCTAssertEqual(calls.count, 2, "an answered prompt writes nothing more")
  }

  func testFailedSettingRecordsNoAnswer() async {
    var calls: [String] = []
    let model = model(
      saveSetting: { _ in
        calls.append("setting")
        throw PutioRuntimeError.transient
      },
      markAnswered: { calls.append("answered") })

    await model.answer(true)

    XCTAssertEqual(calls, ["setting"])
    XCTAssertFalse(model.isAnswered)
    XCTAssertEqual(model.failure, "Check your connection and try again.")
    XCTAssertFalse(model.isSaving)
    XCTAssertNil(model.savingChoice)
  }

  func testRetryAfterAFailedAnswerSendsBothAgain() async {
    var calls: [String] = []
    var answerFailures = 1
    let model = model(
      saveSetting: { calls.append("setting=\($0)") },
      markAnswered: {
        calls.append("answered")
        if answerFailures > 0 {
          answerFailures -= 1
          throw PutioRuntimeError.unknown
        }
      })

    await model.answer(true)
    XCTAssertFalse(model.isAnswered)
    XCTAssertEqual(model.failure, "Could not save your choice. Try again.")

    await model.answer(true)
    XCTAssertEqual(calls, ["setting=true", "answered", "setting=true", "answered"])
    XCTAssertTrue(model.isAnswered)
    XCTAssertNil(model.failure)
  }

  func testSessionLossShowsNoMessage() async {
    let model = model(
      saveSetting: { _ in throw PutioRuntimeError.sessionExpired }, markAnswered: {})

    await model.answer(true)

    XCTAssertNil(model.failure)
    XCTAssertFalse(model.isAnswered)
  }

  private func model(
    saveSetting: @escaping @MainActor @Sendable (Bool) async throws -> Void,
    markAnswered: @escaping @MainActor @Sendable () async throws -> Void
  ) -> PutioProductAnalyticsPromptModel {
    PutioProductAnalyticsPromptModel(
      actions: PutioProductAnalyticsPromptActions(
        saveSetting: saveSetting, markAnswered: markAnswered))
  }
}
