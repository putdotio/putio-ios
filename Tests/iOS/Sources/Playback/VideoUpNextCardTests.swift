import SwiftUI
import Vision
import XCTest

@testable import Putio

@MainActor
final class VideoUpNextCardTests: XCTestCase {
  func testPortraitCardKeepsTheEpisodeMarkerVisible() async throws {
    _ = SnapshotEnvironment.registersBrandFonts
    let portraitPhoneWidths: [CGFloat] = [402, 430, 440]
    for phoneWidth in portraitPhoneWidths {
      for size in [DynamicTypeSize.large, .xxLarge] {
        let lines = try await readCard(chipRowWidth: phoneWidth - 2 * 16, size: size)
        let readsMarker = lines.contains {
          $0.replacingOccurrences(of: "O", with: "0").contains("S04E02")
        }
        XCTAssertTrue(
          readsMarker, "\(Int(phoneWidth)) pt at \(size) hid the episode marker: \(lines)")
      }
    }
  }

  private func readCard(chipRowWidth: CGFloat, size: DynamicTypeSize) async throws -> [String] {
    let card = PutioVideoUpNextAccessory(
      upNext: PutioVideoUpNext(
        offer: .card(name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", secondsLeft: 10),
        onPlay: {}, onCancel: {}),
      iconOnly: false, ownsRow: true)
    let renderer = ImageRenderer(
      content:
        card
        .frame(width: chipRowWidth)
        .padding()
        .background(.black)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(size))
    renderer.scale = 3
    let image = try XCTUnwrap(renderer.cgImage, "the card did not render")

    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let lines = try await request.perform(on: image).compactMap {
      $0.topCandidates(1).first?.string
    }

    let attachment = XCTAttachment(image: UIImage(cgImage: image))
    attachment.name = "up-next-portrait-\(Int(chipRowWidth))-\(size)"
    attachment.lifetime = .keepAlways
    add(attachment)
    return lines
  }
}
