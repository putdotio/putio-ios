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

  #if os(iOS)
    @MainActor func testStatesPageRegularWidth() throws {
      try assertGallerySnapshot(
        page: .states, width: SnapshotEnvironment.regularWidth)
    }
  #endif

  @MainActor func testFeedbackPage() throws {
    try assertGallerySnapshot(page: .feedback)
  }

  @MainActor func testFormsPage() throws {
    try assertGallerySnapshot(page: .forms)
  }

  @MainActor func testSheetsPage() throws {
    try assertGallerySnapshot(page: .sheets)
  }

  #if os(iOS)
    @MainActor func testShellPage() throws {
      try assertGallerySnapshot(page: .shell)
    }

    @MainActor func testMenusPage() throws {
      try assertGallerySnapshot(page: .menus)
    }

    @MainActor func testTextAlertPage() throws {
      try assertGallerySnapshot(page: .textAlert)
    }

    @MainActor func testConfirmAlertPage() throws {
      try assertGallerySnapshot(page: .confirmAlert)
    }

    @MainActor func testSelectionNonePage() throws {
      try assertGallerySnapshot(page: .selectionNone)
    }

    @MainActor func testSelectionSomePage() throws {
      try assertGallerySnapshot(page: .selectionSome)
    }

    @MainActor func testSelectionAllPage() throws {
      try assertGallerySnapshot(page: .selectionAll)
    }

    @MainActor func testSelectionSomePageRegularWidth() throws {
      try assertGallerySnapshot(
        page: .selectionSome, width: SnapshotEnvironment.regularWidth)
    }
  #endif

  #if os(iOS)
    @MainActor func testSplitPage() throws {
      try assertGallerySnapshot(page: .split)
    }

    @MainActor func testSplitPageRegularWidth() throws {
      try assertGallerySnapshot(
        page: .split, width: SnapshotEnvironment.regularWidth)
    }
  #endif

  @MainActor
  private func assertGallerySnapshot(
    page: PutioComponentGallery.Page,
    width: CGFloat = SnapshotEnvironment.width,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) throws {
    try assertBaseline(
      SnapshotRenderer.render(page: page, width: width),
      named: SnapshotEnvironment.platform,
      file: file,
      testName: testName,
      line: line
    )
  }
}
