import SwiftUI
import Vision
import XCTest

@testable import Putio

@MainActor
final class VideoUpNextCardTests: XCTestCase {
  func testPortraitCardKeepsTheEpisodeMarkerVisible() async throws {
    let card = PutioVideoUpNextAccessory(
      upNext: PutioVideoUpNext(
        offer: .card(name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", secondsLeft: 10),
        onPlay: {}, onCancel: {}),
      iconOnly: false)
    let portraitPhoneChipRow: CGFloat = 402 - 2 * 16
    let renderer = ImageRenderer(
      content:
        card
        .frame(width: portraitPhoneChipRow)
        .padding()
        .background(.black)
        .environment(\.colorScheme, .dark))
    renderer.scale = 3
    let image = try XCTUnwrap(renderer.cgImage, "the card did not render")

    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let lines = try await request.perform(on: image).compactMap {
      $0.topCandidates(1).first?.string
    }

    let attachment = XCTAttachment(image: UIImage(cgImage: image))
    attachment.name = "up-next-portrait"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertTrue(
      lines.contains { $0.contains("S04E02") }, "the card hid the episode marker: \(lines)")
  }
}
