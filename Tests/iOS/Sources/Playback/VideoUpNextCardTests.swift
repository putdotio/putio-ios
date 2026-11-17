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
        XCTAssertTrue(
          readsMarker(lines), "\(Int(phoneWidth)) pt at \(size) hid the episode marker: \(lines)")
      }
    }
  }

  func testCardBesideTheChipsKeepsTheEpisodeMarkerVisible() async throws {
    _ = SnapshotEnvironment.registersBrandFonts
    let chipRowWidths: [(device: String, width: CGFloat)] = [
      ("iPhone landscape", 874 - 2 * (62 + 16)), ("iPhone Pro Max landscape", 956 - 2 * (62 + 16)),
      ("iPad portrait", 820 - 2 * 16), ("iPad landscape", 1180 - 2 * 16),
    ]
    for (device, width) in chipRowWidths {
      for size in [DynamicTypeSize.large, .xxLarge] {
        let row = PutioVideoChipRow(
          transport: PutioVideoTransport(), upNext: upNext, onChange: {}, onMenu: { _ in })
        let lines = try await read(row, width: width, size: size, name: "up-next-row")
        XCTAssertTrue(
          readsMarker(lines), "\(device) at \(size) hid the episode marker: \(lines)")
      }
    }
  }

  private let upNext = PutioVideoUpNext(
    offer: .card(name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", secondsLeft: 10),
    onPlay: {}, onCancel: {})

  private func readsMarker(_ lines: [String]) -> Bool {
    lines.contains { $0.replacingOccurrences(of: "O", with: "0").contains("S04E02") }
  }

  private func readCard(chipRowWidth: CGFloat, size: DynamicTypeSize) async throws -> [String] {
    try await read(
      PutioVideoUpNextAccessory(upNext: upNext, iconOnly: false, ownsRow: true),
      width: chipRowWidth, size: size, name: "up-next-portrait")
  }

  private func read(
    _ view: some View, width: CGFloat, size: DynamicTypeSize, name: String
  ) async throws -> [String] {
    let renderer = ImageRenderer(
      content:
        view
        .frame(width: width)
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
    attachment.name = "\(name)-\(Int(width))-\(size)"
    attachment.lifetime = .keepAlways
    add(attachment)
    return lines
  }
}
