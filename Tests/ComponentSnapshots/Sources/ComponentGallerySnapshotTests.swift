import PutioCore
import UIKit
import XCTest

final class ComponentGallerySnapshotTests: XCTestCase {
  @MainActor func testButtonsPage() throws {
    try assertGallerySnapshot(page: .buttons)
  }

  @MainActor func testFilesPage() throws {
    try assertGallerySnapshot(page: .files)
  }

  @MainActor func testTransfersPage() throws {
    try assertGallerySnapshot(page: .transfers)
  }

  @MainActor func testStatesPage() throws {
    try assertGallerySnapshot(page: .states)
  }

  @MainActor func testFeedbackPage() throws {
    try assertGallerySnapshot(page: .feedback)
  }

  @MainActor func testFormsPage() throws {
    try assertGallerySnapshot(page: .forms)
  }

  @MainActor
  private func assertGallerySnapshot(
    page: PutioComponentGallery.Page,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let fileManager = FileManager.default
    let baselineURL = SnapshotEnvironment.baselineDirectory
      .appending(path: "gallery-\(page.rawValue).png")
    let rendered = try SnapshotRenderer.render(page: page)
    let renderedData = try XCTUnwrap(rendered.pngData(), "could not encode rendered snapshot")

    if SnapshotEnvironment.isRecording {
      try fileManager.createDirectory(
        at: SnapshotEnvironment.baselineDirectory, withIntermediateDirectories: true)
      try renderedData.write(to: baselineURL, options: .atomic)
    }

    guard fileManager.fileExists(atPath: baselineURL.path) else {
      XCTFail(
        "missing baseline \(baselineURL.lastPathComponent); "
          + "run mise run harness -- test --platform \(SnapshotEnvironment.platform) "
          + "--snapshots record",
        file: file,
        line: line
      )
      return
    }

    let baselineImage = try XCTUnwrap(
      UIImage(data: try Data(contentsOf: baselineURL))?.cgImage,
      "could not decode baseline \(baselineURL.lastPathComponent)"
    )
    let renderedImage = try XCTUnwrap(rendered.cgImage, "rendered snapshot has no CGImage")
    let comparison = try SnapshotPixels(cgImage: renderedImage)
      .matches(SnapshotPixels(cgImage: baselineImage))
    if !comparison.matches {
      let failureURL = SnapshotEnvironment.failureDirectory
        .appending(path: "gallery-\(page.rawValue).png")
      try? fileManager.createDirectory(
        at: SnapshotEnvironment.failureDirectory, withIntermediateDirectories: true)
      try? renderedData.write(to: failureURL, options: .atomic)
      XCTFail(
        "gallery-\(page.rawValue) diverged from its baseline (\(comparison.detail)); "
          + "rendered image written to \(failureURL.path)",
        file: file,
        line: line
      )
    }
  }
}
