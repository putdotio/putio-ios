import XCTest

extension XCUIApplication {
  var videoClose: XCUIElement {
    descendants(matching: .any)["video.close"]
  }

  func revealVideoControls(
    showing control: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    holdPlayerOrientation()
    for _ in 0..<3 {
      if control.exists { return }
      coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      if control.appears(within: 2) { return }
    }
    XCTFail("the player controls never showed \(control)", file: file, line: line)
  }

  func setVideoPlaying(
    _ playing: Bool, with playPause: XCUIElement, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let target = playing ? "Pause" : "Play"
    let reached = NSPredicate(format: "label == %@", target)
    for _ in 0..<3 {
      revealVideoControls(showing: playPause, file: file, line: line)
      if playPause.label == target { return }
      playPause.tap()
      let expectation = XCTNSPredicateExpectation(predicate: reached, object: playPause)
      if XCTWaiter.wait(for: [expectation], timeout: 3) == .completed { return }
    }
    XCTFail("the player never showed \(target)", file: file, line: line)
  }

  func closeVideo(file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<3 {
      revealVideoControls(showing: videoClose, file: file, line: line)
      videoClose.tap()
      if videoClose.disappears(within: 3) {
        if UIDevice.current.userInterfaceIdiom == .phone {
          XCUIDevice.shared.orientation = .portrait
        }
        return
      }
    }
    XCTFail("Close never dismissed the video", file: file, line: line)
  }

  private func holdPlayerOrientation() {
    let window = windows.firstMatch
    guard window.exists, window.frame.width > window.frame.height,
      !XCUIDevice.shared.orientation.isLandscape
    else { return }
    XCUIDevice.shared.orientation = .landscapeLeft
    _ = videoClose.waitForExistence(timeout: 2)
  }
}
