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
    XCTAssertEqual(
      root.items.map(\.id),
      [folderID, PutioFileID(rawValue: 412), PutioFileID(rawValue: 413)]
    )
    XCTAssertEqual(folderRoute.id, folderID)
    XCTAssertEqual(nested.folder?.id, folderID)
    XCTAssertEqual(nested.items.map(\.id), [fileID])
    XCTAssertEqual(fileRoute.id, fileID)
    XCTAssertEqual(fileRoute.item.parentID, folderID)
    XCTAssertEqual(fileRoute.item.kind, .video)
  }

  func testEverySeededVideoResolvesToPlayback() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .filesBrowser)
    await runtime.session.restore()

    let root = try await runtime.listFiles(parentID: .root)
    let nested = try await runtime.listFiles(parentID: PutioFileID(rawValue: 410))
    let videos = (root.items + nested.items).filter { $0.kind == .video }

    var sources: [Int: PutioPlaybackSource] = [:]
    for video in videos {
      guard
        case .ready(let source) = try await runtime.resolveVideoPlaybackSource(
          fileID: video.id
        )
      else {
        return XCTFail("expected seeded video \(video.id.rawValue) to be ready")
      }
      sources[video.id.rawValue] = source
    }

    XCTAssertEqual(Set(sources.keys), [411, 412])
    XCTAssertEqual(sources[411]?.url.path, "/v2/files/411/hls/media.m3u8")
    XCTAssertEqual(sources[411]?.startFromSeconds, 90)
    XCTAssertEqual(sources[412]?.url.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertEqual(sources[412]?.startFromSeconds, 0)
  }
}
