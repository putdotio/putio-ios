import XCTest

final class ContinueWatchingJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testStartedVideoIsListedRemovedFinishedAndTrashed() {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    let root = element("files.screen.0")
    XCTAssertTrue(root.appears(within: 10), "the Files root never appeared")
    let section = element("files.continue-watching")
    let allFiles = element("files.all-files")
    XCTAssertTrue(allFiles.appears(within: 5), "the root has no All files header")
    XCTAssertEqual(allFiles.label, "All files, 30.62 GB of 1.1 TB")
    XCTAssertFalse(section.exists, "Continue watching showed before anything was played")

    playNestedMovieToTheMiddle(convertsFirst: true)
    let card = element("files.continue-watching.item.411")
    XCTAssertTrue(card.appears(within: 10), "the started video never got a card")
    XCTAssertTrue(
      card.label.hasPrefix("Resume Nested Movie.mkv, ") && card.label.hasSuffix(" left"),
      "the card reads \(card.label)")
    addScreenshot(named: "continue-watching-card")

    card.press(forDuration: 1)
    let remove = app.buttons["Remove from Continue watching"]
    XCTAssertTrue(remove.appears(within: 5), "the card offers no Remove")
    addScreenshot(named: "continue-watching-menu")
    remove.tap()
    XCTAssertTrue(card.disappears(within: 5), "Remove left the card")
    XCTAssertFalse(section.exists, "the empty section stayed on the root")

    let rootVideo = element("files.item.412")
    XCTAssertTrue(rootVideo.becomesHittable(within: 5), "the root video is not tappable")
    rootVideo.tap()
    app.answerResumePrompt()
    XCTAssertTrue(element("video.ready").appears(within: 15), "the root video never played")
    XCTAssertTrue(element("video.ended").appears(within: 45), "the root video never finished")
    app.closeVideo()
    XCTAssertTrue(root.appears(within: 10), "the player did not return to the root")
    XCTAssertFalse(
      element("files.continue-watching.item.412").shows(within: 3),
      "a finished video got a card")
    XCTAssertFalse(section.exists, "a finished video showed the section")
    addScreenshot(named: "continue-watching-none")

    playNestedMovieToTheMiddle(convertsFirst: false)
    XCTAssertTrue(card.appears(within: 10), "playing again did not bring the card back")

    let folder = element("files.item.410")
    XCTAssertTrue(folder.becomesHittable(within: 5), "the Harness Folder is not tappable")
    folder.press(forDuration: 1)
    let trash = app.buttons["Move to trash"]
    XCTAssertTrue(trash.appears(within: 5), "the folder offers no Move to trash")
    trash.tap()
    XCTAssertTrue(folder.disappears(within: 10), "the trashed folder stayed")
    XCTAssertTrue(card.disappears(within: 10), "a video in the trashed folder kept its card")
    XCTAssertFalse(section.exists, "the section stayed after its last video was trashed")
  }

  private func playNestedMovieToTheMiddle(convertsFirst: Bool) {
    let folder = element("files.item.410")
    XCTAssertTrue(folder.becomesHittable(within: 10), "the Harness Folder is not tappable")
    folder.tap()
    let video = element("files.item.411")
    XCTAssertTrue(video.appears(within: 10), "the nested video never appeared")
    video.tap()
    if !convertsFirst { app.answerResumePrompt() }
    XCTAssertTrue(app.videoClose.appears(within: 10), "the player never opened")
    if convertsFirst {
      XCTAssertTrue(element("video.error").appears(within: 10), "the conversion never failed")
      app.buttons["Try again"].tap()
      app.answerResumePrompt()
    }
    XCTAssertTrue(element("video.ready").appears(within: 20), "the nested video never played")
    let position = element("video.current-position")
    let started = Int(element("video.resume-position").value as? String ?? "") ?? 0
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let element = object as? XCUIElement else { return false }
        return Int(element.value as? String ?? "") ?? -1 > started
      },
      object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed, "playback never moved")
    app.closeVideo()
    XCTAssertTrue(element("files.screen.410").appears(within: 10), "the player did not close")
    app.navigationBars["Harness Folder"].buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10), "the root never came back")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
