import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FilesBrowserSeededAPIIntegrationTests: XCTestCase {
  func testRootFolderAndNestedFileFlow() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .filesBrowser)
    await runtime.session.restore()

    guard case .signedIn = runtime.session.state else {
      return XCTFail("expected seeded session to restore")
    }

    let folderID = PutioFileID(rawValue: 410)
    let fileID = PutioFileID(rawValue: 411)
    let root = try await runtime.listFiles(parentID: .root)
    let folder = try XCTUnwrap(root.items.first { $0.id == folderID })
    let folderRoute = try XCTUnwrap(
      PutioBrowserItemPresentation(item: folder).folderRoute
    )
    let nested = try await runtime.listFiles(parentID: folderRoute.id)
    let file = try XCTUnwrap(nested.items.first { $0.id == fileID })
    let fileRoute = try XCTUnwrap(
      PutioBrowserItemPresentation(item: file).fileRoute
    )

    XCTAssertEqual(root.folder?.id, .root)
    XCTAssertEqual(root.items.map(\.id), [folderID, PutioFileID(rawValue: 412)])
    XCTAssertEqual(folderRoute.id, folderID)
    XCTAssertEqual(nested.folder?.id, folderID)
    XCTAssertEqual(nested.items.map(\.id), [fileID])
    XCTAssertEqual(fileRoute.id, fileID)
    XCTAssertEqual(fileRoute.item.parentID, folderID)
    XCTAssertEqual(fileRoute.item.kind, .video)
  }
}
