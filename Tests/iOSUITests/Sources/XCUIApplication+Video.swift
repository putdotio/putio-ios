import XCTest

extension XCUIApplication {
  var mainWindow: XCUIElement {
    windows.allElementsBoundByIndex.first { !$0.frame.isEmpty } ?? windows.firstMatch
  }

  var videoClose: XCUIElement {
    descendants(matching: .any)["video.close"]
  }

  func revealVideoControls(
    showing control: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    for _ in 0..<3 {
      if control.exists, control.isHittable { return }
      mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      if control.waitForExistence(timeout: 2), control.isHittable { return }
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
      playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      let expectation = XCTNSPredicateExpectation(predicate: reached, object: playPause)
      if XCTWaiter.wait(for: [expectation], timeout: 3) == .completed { return }
    }
    XCTFail("the player never showed \(target)", file: file, line: line)
  }

  func videoRouteGroup(file: StaticString = #filePath, line: UInt = #line) -> [String] {
    let routes = ["video.picture-in-picture", "video.airplay", "cast.button"].map {
      descendants(matching: .any)[$0]
    }
    revealVideoControls(showing: routes[1], file: file, line: line)
    let row = routes[1].frame.midY
    return routes.filter { $0.exists && abs($0.frame.midY - row) < 4 }
      .sorted { $0.frame.minX < $1.frame.minX }
      .map(\.identifier)
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
