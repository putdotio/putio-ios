import XCTest

@testable import PutioDomain

final class HarnessMediaTests: XCTestCase {
  func testOnlyALoopbackHTTPServerServesHarnessMedia() {
    func baseURL(_ raw: String?) -> URL? {
      HarnessMediaServer.baseURL(
        environment: raw.map { [HarnessMediaServer.environmentKey: $0] } ?? [:])
    }
    XCTAssertEqual(baseURL("http://127.0.0.1:8123/"), URL(string: "http://127.0.0.1:8123/"))
    XCTAssertNil(baseURL(nil))
    XCTAssertNil(baseURL("https://127.0.0.1:8123/"))
    XCTAssertNil(baseURL("http://localhost:8123/"))
    XCTAssertNil(baseURL("http://media.example.com/"))
    XCTAssertNil(baseURL("not a url"))
  }

  func testConversionHistoryKeepsEachPhaseChangeOnce() {
    var history = HarnessConversionHistory()
    XCTAssertNil(history.value)
    for state: PutioVideoPlaybackState in [
      .loading, .conversionRequired, .conversionQueued, .conversionQueued,
      .converting(progress: 0.2), .converting(progress: 0.6), .conversionCompleted, .loading,
    ] {
      history.record(state)
    }
    XCTAssertEqual(history.value, "queued,converting,completed")
  }
}
