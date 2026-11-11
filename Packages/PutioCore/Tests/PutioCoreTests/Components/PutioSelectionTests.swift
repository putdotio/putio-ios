import XCTest

@testable import PutioCore

final class PutioSelectionTests: XCTestCase {
  private let ids = [1, 2, 3]

  func testHeaderStatesFollowTheSelectedRows() {
    var selection = PutioSelection<Int>()
    selection.begin()
    XCTAssertEqual(selection.coverage(among: ids), .none)

    selection.toggle(1)
    selection.toggle(3)
    XCTAssertEqual(selection.coverage(among: ids), .some)
    XCTAssertEqual(selection.count, 2)

    selection.selectAll(among: ids)
    XCTAssertEqual(selection.coverage(among: ids), .all)
    XCTAssertEqual(selection.count, 3)

    selection.selectAll(among: ids)
    XCTAssertEqual(selection.coverage(among: ids), .all)
    XCTAssertTrue(selection.isActive)
  }

  func testTogglingTwiceDeselectsTheRow() {
    var selection = PutioSelection<Int>(isActive: true)
    selection.toggle(2)
    selection.toggle(2)
    XCTAssertFalse(selection.contains(2))
  }

  func testRowsDoNotToggleOutsideSelection() {
    var selection = PutioSelection<Int>()
    selection.toggle(1)
    selection.selectAll(among: ids)
    XCTAssertEqual(selection.count, 0)
  }

  func testEndingClearsTheSelection() {
    var selection = PutioSelection<Int>(isActive: true, selectedIDs: [1, 2])
    selection.end()
    XCTAssertFalse(selection.isActive)
    selection.begin()
    XCTAssertEqual(selection.count, 0)
  }

  func testRefreshKeepsRowsThatRemain() {
    var selection = PutioSelection<Int>(isActive: true, selectedIDs: [1, 2])
    selection.retain([2, 3, 4])
    XCTAssertTrue(selection.isActive)
    XCTAssertEqual(selection.selectedIDs, [2])
  }

  func testActionsBeyondTheLimitMoveUnderMore() {
    let four = PutioSelectionBarLayout(["move", "download", "watched", "trash"])
    XCTAssertEqual(four.visible, ["move", "download", "watched", "trash"])
    XCTAssertTrue(four.overflow.isEmpty)

    let five = PutioSelectionBarLayout(["move", "download", "watched", "rename", "trash"])
    XCTAssertEqual(five.visible, ["move", "download", "watched"])
    XCTAssertEqual(five.overflow, ["rename", "trash"])
  }
}
