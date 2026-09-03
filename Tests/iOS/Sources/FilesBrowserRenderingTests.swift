import PutioCore
import SwiftUI
import UIKit
import XCTest

@testable import Putio

final class FilesBrowserRenderingTests: XCTestCase {
  @MainActor
  func testNextVideoOverlayMatchesBaseline() throws {
    let overlay = PutioNextVideoOverlay(
      nextVideo: PutioNextVideo(
        id: PutioFileID(rawValue: 414),
        parentID: .root,
        name: "Big Buck Bunny.mkv"
      ),
      onPlay: {},
      onCancel: {}
    )
    .padding(PutioTheme.Spacing.space4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .background(
      LinearGradient(
        colors: [PutioTheme.Colors.surface, PutioTheme.Colors.accent.opacity(0.25)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )

    let viewport = CGSize(width: 390, height: 320)
    let image = try assertRenderingSnapshot(
      name: "video-next-overlay",
      view: overlay,
      size: viewport
    )

    XCTAssertEqual(image.size, viewport)
  }

  @MainActor
  func testLoadedBrowserMatchesDefaultAndAccessibilityBaselines() throws {
    let contents = BrowserTestFixtures.contents(
      items: [
        BrowserTestFixtures.item(id: 410, name: "Harness Folder", kind: .folder),
        BrowserTestFixtures.item(
          id: 411,
          name: "Nested Movie.mkv",
          kind: .video,
          sizeBytes: 4_682_500_000,
          resumePositionSeconds: 120
        ),
      ],
      hasMore: true
    )
    let screen = NavigationStack {
      PutioFolderScreen(
        route: .root,
        load: { _ in contents },
        actions: PutioFileActions(
          createFolder: { _, _ in BrowserTestFixtures.item(id: 999, kind: .folder) },
          renameFile: { _, _ in },
          deleteFile: { _ in },
          moveFile: { _, _ in }
        ),
        initialContents: contents,
        relativeTo: BrowserTestFixtures.referenceDate,
        locale: Locale(identifier: "en_US"),
        onFileSelected: { _ in }
      )
    }
    .tint(PutioTheme.Colors.accent)
    let viewport = CGSize(width: 390, height: 844)

    let defaultImage = try assertRenderingSnapshot(
      name: "browser-root-default",
      view: screen,
      size: viewport
    )
    let accessibilityImage = try assertRenderingSnapshot(
      name: "browser-root-accessibility3",
      view: screen,
      size: viewport,
      dynamicTypeSize: .accessibility3
    )

    XCTAssertEqual(defaultImage.size, viewport)
    XCTAssertEqual(accessibilityImage.size, viewport)
    let defaultPixels = try SnapshotPixels(cgImage: XCTUnwrap(defaultImage.cgImage))
    let accessibilityPixels = try SnapshotPixels(cgImage: XCTUnwrap(accessibilityImage.cgImage))
    XCTAssertFalse(defaultPixels.matches(accessibilityPixels).matches)
  }

  @MainActor
  private func assertRenderingSnapshot<Content: View>(
    name: String,
    view: Content,
    size: CGSize,
    dynamicTypeSize: DynamicTypeSize = .large,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIImage {
    let fileManager = FileManager.default
    let baselineURL = SnapshotEnvironment.baselineDirectory.appending(path: "\(name).png")
    let rendered = try SnapshotRenderer.render(
      view: view,
      size: size,
      dynamicTypeSize: dynamicTypeSize
    )
    let renderedData = try XCTUnwrap(rendered.pngData(), "could not encode rendered snapshot")

    if SnapshotEnvironment.isRecording {
      try fileManager.createDirectory(
        at: SnapshotEnvironment.baselineDirectory,
        withIntermediateDirectories: true
      )
      try renderedData.write(to: baselineURL, options: .atomic)
    }

    guard fileManager.fileExists(atPath: baselineURL.path) else {
      XCTFail(
        "missing baseline \(baselineURL.lastPathComponent); "
          + "run mise run harness -- test --platform ios --snapshots record",
        file: file,
        line: line
      )
      return rendered
    }

    let baselineImage = try XCTUnwrap(
      UIImage(data: try Data(contentsOf: baselineURL))?.cgImage,
      "could not decode baseline \(baselineURL.lastPathComponent)"
    )
    let renderedImage = try XCTUnwrap(rendered.cgImage, "rendered snapshot has no CGImage")
    let comparison = try SnapshotPixels(cgImage: renderedImage)
      .matches(SnapshotPixels(cgImage: baselineImage))
    if !comparison.matches {
      let failureURL = SnapshotEnvironment.failureDirectory.appending(path: "\(name).png")
      try? fileManager.createDirectory(
        at: SnapshotEnvironment.failureDirectory,
        withIntermediateDirectories: true
      )
      try? renderedData.write(to: failureURL, options: .atomic)
      XCTFail(
        "\(name) diverged from its baseline (\(comparison.detail)); "
          + "rendered image written to \(failureURL.path)",
        file: file,
        line: line
      )
    }
    return rendered
  }
}
