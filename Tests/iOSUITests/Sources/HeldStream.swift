import XCTest

struct HeldStream {
  enum Hold: String {
    case start
    case middle
  }

  let token = UUID().uuidString

  func environment(_ hold: Hold) -> String {
    "\(hold.rawValue):\(token)"
  }

  func release(file: StaticString = #filePath, line: UInt = #line) {
    guard
      let base = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
      let url = URL(string: base)?.appending(path: "release/\(token)")
    else {
      return XCTFail("no loopback media server to release the held stream", file: file, line: line)
    }
    let released = XCTestExpectation(description: "held stream released")
    URLSession.shared.dataTask(with: url) { _, response, _ in
      if (response as? HTTPURLResponse)?.statusCode == 204 { released.fulfill() }
    }.resume()
    XCTAssertEqual(
      XCTWaiter.wait(for: [released], timeout: 5), .completed,
      "the media server never released the held stream", file: file, line: line)
  }
}
