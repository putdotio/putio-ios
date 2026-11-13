import XCTest

extension XCUIApplication {
  var videoClose: XCUIElement {
    descendants(matching: .any)["video.close"]
  }

  func revealVideoControls(
    showing control: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    for _ in 0..<3 {
      if control.exists, control.isHittable { return }
      coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      if control.becomesHittable(within: 2) { return }
    }
    XCTFail("the player controls never showed \(control)", file: file, line: line)
  }

  func closeVideo(file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<3 {
      revealVideoControls(showing: videoClose, file: file, line: line)
      videoClose.tap()
      if videoClose.disappears(within: 3) { return }
    }
    XCTFail("Close never dismissed the video", file: file, line: line)
  }
}
