import PutioCore
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

  func testPortraitTopBarKeepsTheEpisodeMarkerVisible() async throws {
    _ = SnapshotEnvironment.registersBrandFonts
    for phoneWidth: CGFloat in [402, 430, 440] {
      for size in [DynamicTypeSize.large, .xxLarge] {
        let topBar = PutioVideoTopBar(
          title: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv", onClose: {}
        ) { EmptyView() }
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .regular)
        let lines = try await read(
          topBar, width: phoneWidth - 2 * PutioTheme.Spacing.space3, size: size,
          name: "top-bar-portrait")
        XCTAssertTrue(
          readsMarker(lines, "S04E01"),
          "\(Int(phoneWidth)) pt at \(size) hid the episode marker: \(lines)")
      }
    }
  }

  func testCardBesideTheChipsKeepsTheEpisodeMarkerVisible() async throws {
    _ = SnapshotEnvironment.registersBrandFonts
    let chipRowWidths: [(device: String, width: CGFloat)] = [
      ("iPhone landscape", 874 - 2 * (62 + 16)), ("iPhone Pro Max landscape", 956 - 2 * (62 + 16)),
      ("iPad portrait", 820 - 2 * 16), ("iPad landscape", 1180 - 2 * 16),
    ]
    for size in [DynamicTypeSize.large, .xxLarge] {
      let card = PutioVideoUpNextAccessory(upNext: upNext, iconOnly: false).fixedSize()
      let lines = try await read(card, width: 640, size: size, name: "up-next-ideal")
      XCTAssertTrue(
        readsMarker(lines), "the card's ideal width at \(size) hid the marker: \(lines)")
    }
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

  func testCardBesideTheChipsKeepsTheMarkerOfALongSeriesName() async throws {
    _ = SnapshotEnvironment.registersBrandFonts
    let longName = PutioVideoUpNext(
      offer: .card(
        name: "Star.Trek.Strange.New.Worlds.Behind.the.Scenes.S02E05.1080p.WEB.H264-GROUP.mkv",
        secondsLeft: 10),
      onPlay: {}, onCancel: {})
    for size in [DynamicTypeSize.large, .xxLarge] {
      let card = PutioVideoUpNextAccessory(upNext: longName, iconOnly: false).fixedSize()
      let lines = try await read(card, width: 640, size: size, name: "up-next-long")
      XCTAssertTrue(
        readsMarker(lines, "S02E05"), "a long series name at \(size) hid the marker: \(lines)")
    }
  }

  func testLandscapePhoneFitsTheBoardChipLabelsBesideTheCard() throws {
    _ = SnapshotEnvironment.registersBrandFonts
    let boardChips = HStack(spacing: PutioTheme.Spacing.space2) {
      PutioVideoChipLabel(icon: .speakerHigh, title: "English", iconOnly: false)
      PutioVideoChipLabel(icon: .closedCaptioning, title: "English", iconOnly: false)
      PutioVideoChipLabel(icon: .gauge, title: "1x", iconOnly: false)
    }
    let card = PutioVideoUpNextAccessory(upNext: upNext, iconOnly: false)
    let rowWidth = try idealWidth(boardChips) + 3 * PutioTheme.Spacing.space2 + idealWidth(card)
    XCTAssertLessThanOrEqual(
      rowWidth, 874 - 2 * (62 + 16),
      "\(rowWidth) pt: the board's labelled chips no longer fit beside the card")
  }

  private func idealWidth(_ view: some View) throws -> CGFloat {
    let renderer = ImageRenderer(content: view.fixedSize().dynamicTypeSize(.large))
    renderer.scale = 1
    return CGFloat(try XCTUnwrap(renderer.cgImage, "the view did not render").width)
  }

  private let upNext = PutioVideoUpNext(
    offer: .card(name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", secondsLeft: 10),
    onPlay: {}, onCancel: {})

  private func readsMarker(_ lines: [String], _ marker: String = "S04E02") -> Bool {
    lines.contains { $0.replacingOccurrences(of: "O", with: "0").contains(marker) }
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
