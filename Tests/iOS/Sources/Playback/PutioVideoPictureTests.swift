import XCTest

@testable import Putio

@MainActor
final class PutioVideoPictureTests: XCTestCase {
  private let cue = CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.05)

  func testALetterboxedCueStaysInsideThePicture() {
    let picture = PutioVideoPicture(
      coded: CGSize(width: 1920, height: 1080), display: CGSize(width: 1920, height: 1080))

    let frame = picture.frame(
      ofBitmapAt: cue, canvas: CGSize(width: 1920, height: 1080),
      in: CGRect(x: 0, y: 0, width: 1000, height: 1000))

    assertFrame(frame, CGRect(x: 250, y: 725, width: 500, height: 28.125))
  }

  func testAnAnamorphicCanvasMapsOntoTheCodedFrameBeforeTheDisplayedPicture() {
    let picture = PutioVideoPicture(
      coded: CGSize(width: 1440, height: 1080), display: CGSize(width: 1920, height: 1080))

    let frame = picture.frame(
      ofBitmapAt: cue, canvas: CGSize(width: 1920, height: 1080),
      in: CGRect(x: 0, y: 0, width: 1920, height: 1080))

    assertFrame(frame, CGRect(x: 480, y: 864, width: 960, height: 40.5))
  }

  private func assertFrame(
    _ frame: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line
  ) {
    for (actual, wanted) in zip(
      [frame.minX, frame.minY, frame.width, frame.height],
      [expected.minX, expected.minY, expected.width, expected.height])
    {
      XCTAssertEqual(actual, wanted, accuracy: 0.001, file: file, line: line)
    }
  }
}
