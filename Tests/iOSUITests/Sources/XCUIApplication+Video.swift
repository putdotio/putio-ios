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
      if control.exists, control.becomesHittable(within: 3) { return }
      mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      if control.becomesHittable(within: 5) { return }
    }
    XCTFail("the player controls never showed \(control)", file: file, line: line)
  }

  func readVideoControl(
    _ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) -> (any XCUIElementSnapshot)? {
    for _ in 0..<3 {
      revealVideoControls(showing: control, file: file, line: line)
      if let shown = try? control.snapshot() { return shown }
    }
    XCTFail("the player controls hid before \(control) was read", file: file, line: line)
    return nil
  }

  func tapVideoControl(
    _ control: XCUIElement, failing message: String, file: StaticString = #filePath,
    line: UInt = #line, until reached: () -> Bool
  ) {
    let host = mainWindow
    let window = host.frame
    for _ in 0..<3 {
      if reached() { return }
      revealVideoControls(showing: control, file: file, line: line)
      guard control.becomesTappable(within: 10), let shown = try? control.snapshot() else {
        continue
      }
      if reached() { return }
      host.coordinate(withNormalizedOffset: .zero)
        .withOffset(
          CGVector(dx: shown.frame.midX - window.minX, dy: shown.frame.midY - window.minY)
        ).tap()
      if waits(5, until: reached) { return }
    }
    XCTFail(message, file: file, line: line)
  }

  func setVideoPlaying(
    _ playing: Bool, with playPause: XCUIElement, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let target = playing ? "Pause" : "Play"
    tapVideoControl(
      playPause, failing: "the player never showed \(target)", file: file, line: line
    ) {
      (try? playPause.snapshot())?.label == target
    }
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
    let player = ["video.ready", "video.error"].map { descendants(matching: .any)[$0] }
    tapVideoControl(
      videoClose, failing: "Close never dismissed the video", file: file, line: line
    ) {
      !videoClose.exists && !player.contains { $0.exists }
    }
  }

  private func waits(_ timeout: TimeInterval, until reached: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !reached() {
      guard Date.now < deadline else { return false }
      RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.1)))
    }
    return true
  }
}
