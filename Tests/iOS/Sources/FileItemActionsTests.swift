import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FileItemActionsTests: XCTestCase {
  func testSearchResultActionsReachTheFileActionBoundary() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    let destination = PutioFolderRoute(id: PutioFileID(rawValue: 91), title: "Season 2")
    var calls: [String] = []
    let model = PutioFileItemActionModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { fileID, name in calls.append("rename \(fileID.rawValue) \(name)") },
        deleteFile: { fileID in calls.append("delete \(fileID.rawValue)") },
        moveFile: { fileID, parentID in
          calls.append("move \(fileID.rawValue) \(parentID.rawValue)")
        }
      ))

    await model.rename(item, to: "  Renamed.mkv ")
    XCTAssertEqual(
      model.outcome,
      .succeeded(.rename(fileID: item.id, oldName: item.name, newName: "Renamed.mkv")))
    await model.move(item, to: destination)
    XCTAssertEqual(
      model.outcome,
      .succeeded(
        .move(
          fileID: item.id, name: item.name, sourceParentID: item.parentID,
          destinationID: destination.id, destinationName: destination.title)))
    await model.delete(item)

    XCTAssertEqual(calls, ["rename 7 Renamed.mkv", "move 7 91", "delete 7"])
    XCTAssertEqual(model.outcome, .succeeded(.delete(fileID: item.id, name: item.name)))
    XCTAssertNil(model.activeAction)
  }

  func testSearchResultActionFailureIsReportedAndNoOpsSendNothing() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    var moveCount = 0
    let model = PutioFileItemActionModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.rateLimited },
        deleteFile: { _ in XCTFail("deletion must wait for resolved preferences") },
        moveFile: { _, _ in moveCount += 1 },
        canDelete: { false }
      ))

    await model.rename(item, to: item.name)
    XCTAssertNil(model.outcome, "an unchanged name must not send a rename")
    await model.move(item, to: PutioFolderRoute(id: item.parentID, title: "Current"))
    XCTAssertEqual(moveCount, 0)
    await model.delete(item)
    XCTAssertNil(model.outcome)

    await model.rename(item, to: "Renamed.mkv")
    guard case .failed(.rename, let failure) = model.outcome else {
      return XCTFail("expected a rename failure")
    }
    XCTAssertEqual(failure.title, "Could not rename item")
  }
}
