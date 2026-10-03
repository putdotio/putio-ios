import XCTest

@testable import PutioCore

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
      ), refreshRequests: PutioFolderRefreshRequests())

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
      ), refreshRequests: PutioFolderRefreshRequests())

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
  func testFailedTrashMoveShowsTheSearchRowAgain() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    let model = PutioFileItemActionModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.transient }
      ), refreshRequests: PutioFolderRefreshRequests())

    model.hideForTrash(item)
    XCTAssertEqual(model.hiddenIDs, [item.id], "the row leaves with the tap")
    await model.delete(item)

    XCTAssertEqual(model.hiddenIDs, [], "a move that did not commit must show the row again")
  }

  func testSettledActionsRefreshSearchAndCommittedDeletesStayHidden() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    let requests = PutioFolderRefreshRequests()
    let model = PutioFileItemActionModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in },
        deleteFile: { _ in }
      ), refreshRequests: requests)

    let beforeRename = requests.revision
    await model.rename(item, to: "Renamed.mkv")
    XCTAssertGreaterThan(requests.revision, beforeRename, "a rename must re-run the search")

    let beforeDelete = requests.revision
    await model.delete(item)
    XCTAssertGreaterThan(requests.revision, beforeDelete, "a delete must re-run the search")
    XCTAssertEqual(model.hiddenIDs, [item.id], "a deleted row must not stay actionable")

    model.revealHiddenItems()
    XCTAssertEqual(model.hiddenIDs, [])
  }

  func testSearchResultWatchStatusRefreshesItsFolderAndSkipsNoOps() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    let audio = BrowserTestFixtures.item(id: 8, parentID: 42, kind: .audio)
    let requests = PutioFolderRefreshRequests()
    let folder = PutioFolderRefreshRegistration(
      folderID: PutioFileID(rawValue: 42), requests: requests)
    folder.activate()
    var calls: [String] = []
    let model = PutioFileItemActionModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in },
        deleteFile: { _ in },
        setWatched: { fileID, watched in calls.append("\(fileID.rawValue) \(watched)") }
      ), refreshRequests: requests)

    await model.setWatched(item, false)
    await model.setWatched(audio, true)
    XCTAssertEqual(calls, [])
    XCTAssertNil(model.outcome)

    await model.setWatched(item, true)
    XCTAssertEqual(calls, ["7 true"])
    XCTAssertEqual(
      model.outcome,
      .succeeded(
        .setWatched(fileID: item.id, parentID: item.parentID, name: item.name, watched: true)))
    XCTAssertNotNil(
      requests.sequence(for: item.parentID, owner: folder.owner),
      "the folder showing the video must refresh, which also re-runs the search")
  }
}
