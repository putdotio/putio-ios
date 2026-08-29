import PutioCore
import SwiftUI
import XCTest

@testable import Putio

final class FilesBrowserRenderingTests: XCTestCase {
  @MainActor
  func testLoadedBrowserRendersAtDefaultAndAccessibilityTypeSizes() throws {
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
        initialContents: contents,
        onFileSelected: { _ in }
      )
    }
    let viewport = CGSize(width: 390, height: 844)

    let defaultImage = try SnapshotRenderer.render(view: screen, size: viewport)
    let accessibilityImage = try SnapshotRenderer.render(
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
}
