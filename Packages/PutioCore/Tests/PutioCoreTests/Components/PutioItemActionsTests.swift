import XCTest

@testable import PutioCore

final class PutioItemActionsTests: XCTestCase {
  func testDestructiveItemsCloseTheMenuInTheirOwnSection() {
    let menu = PutioItemMenu([
      [action("play"), action("trash", role: .destructive), action("download")],
      [action("rename")],
      [],
    ])

    XCTAssertEqual(
      menu.sections.map { $0.map(\.id) }, [["play", "download"], ["rename"], ["trash"]])
  }

  func testTextAlertSelectsTheNameWithoutItsExtension() {
    XCTAssertEqual(
      PutioTextAlert.selectedLength(of: "Blue.Lights.S04E01.en.srt"),
      "Blue.Lights.S04E01.en".utf16.count)
    XCTAssertEqual(PutioTextAlert.selectedLength(of: "Blue Lights"), "Blue Lights".utf16.count)
    XCTAssertEqual(PutioTextAlert.selectedLength(of: ".hidden"), ".hidden".utf16.count)
    XCTAssertEqual(PutioTextAlert.selectedLength(of: "Séries 🎬.mkv"), "Séries 🎬".utf16.count)
  }

  func testTextAlertSubmitsOnlyANewNonEmptyName() {
    XCTAssertFalse(PutioTextAlert.canSubmit("a.srt", replacing: "a.srt"))
    XCTAssertFalse(PutioTextAlert.canSubmit("  ", replacing: "a.srt"))
    XCTAssertFalse(PutioTextAlert.canSubmit("a.srt ", replacing: "a.srt"))
    XCTAssertTrue(PutioTextAlert.canSubmit("b.srt", replacing: "a.srt"))
  }

  private func action(_ id: String, role: PutioItemAction.Role = .standard) -> PutioItemAction {
    PutioItemAction(id: id, title: id, icon: .file, role: role) {}
  }
}
