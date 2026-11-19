import XCTest

final class FileRowGalleryTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", "files",
    ]
  }

  func testTrailingControlsReportTheActionForTheirState() {
    app.launch()

    let cases: [(label: String, episode: String, reported: String)] = [
      ("Pause download", "02", "pause"),
      ("Pause download", "05", "pause"),
      ("Resume download", "03", "resume"),
      ("Pause download", "06", "pause"),
      ("Pause download", "08", "pause"),
      ("Cancel download", "07", "cancel"),
      ("Download again", "10", "download-again"),
      ("Retry download", "11", "retry"),
    ]
    let reported = app.staticTexts["gallery.files.reported-action"]
    XCTAssertTrue(reported.appears(within: 10), "gallery Files page never appeared")

    for entry in cases {
      let name = "Blue.Lights.S04E\(entry.episode).1080p.HDTV.H264-ORGANiC.mkv"
      let control = revealedButton("\(entry.label), \(name)")
      XCTAssertTrue(
        control.appears(within: 5) && control.becomesHittable(within: 5),
        "no trailing control for \(name)")
      control.tap()
      revealTop()
      let expected = "Last action: \(entry.reported) \(name)"
      let landed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label == %@", expected), object: reported)
      _ = XCTWaiter.wait(for: [landed], timeout: 5 * XCUIElement.timeoutScale)
      XCTAssertEqual(reported.label, expected)
    }
  }

  private func revealedButton(_ label: String) -> XCUIElement {
    let button = app.buttons[label]
    var swipes = 0
    while !button.isHittable, swipes < 6 {
      app.swipeUp()
      swipes += 1
    }
    return button
  }

  private func revealTop() {
    var swipes = 0
    while !app.staticTexts["gallery.files.reported-action"].isHittable, swipes < 6 {
      app.swipeDown()
      swipes += 1
    }
  }
}
