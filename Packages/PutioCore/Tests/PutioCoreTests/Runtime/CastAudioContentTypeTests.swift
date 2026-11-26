import XCTest

@testable import PutioCore

@MainActor
final class CastAudioContentTypeTests: XCTestCase {
  func testAudioContentTypeComesFromTheFileExtension() {
    XCTAssertEqual(PutioRuntime.audioContentType(fileName: "Session.mp3"), "audio/mpeg")
    XCTAssertEqual(PutioRuntime.audioContentType(fileName: "Session"), "audio/mpeg")
  }
}
