import PutioCore
import SwiftUI
import XCTest

@testable import PutioTV

/// The Move sheet's states with the board's folders, rendered without the
/// list behind it.
@MainActor
final class TVMoveSheetTests: XCTestCase {
  private let viewport = CGSize(width: 1920, height: 1080)

  func testYourFilesMarksTheItemsFolderMatchesBaseline() async throws {
    let root = try await level(.root, folders: Self.rootFolders)
    _ = try assertRenderingSnapshot(
      name: "tv-files-move", view: sheet([root]), size: viewport)
  }

  func testInsideAFolderMatchesBaseline() async throws {
    let levels = [
      try await level(.root, folders: Self.rootFolders),
      try await level(Self.documentaries, folders: Self.documentaryFolders),
    ]
    _ = try assertRenderingSnapshot(
      name: "tv-files-move-inside", view: sheet(levels), size: viewport)
  }

  func testAnEmptyFolderMatchesBaseline() async throws {
    let levels = [
      try await level(.root, folders: Self.rootFolders),
      try await level(Self.documentaries, folders: Self.documentaryFolders),
      try await level(
        PutioFolderRoute(id: PutioFileID(rawValue: 31), title: "Nature"), folders: []),
    ]
    _ = try assertRenderingSnapshot(
      name: "tv-files-move-empty", view: sheet(levels), size: viewport)
  }

  func testAFailedFolderMatchesBaseline() async throws {
    let failed = TVMoveSheet.Level(
      route: Self.documentaries,
      model: PutioFolderModel(folderID: Self.documentaries.id) { _ in
        throw PutioFolderLoadError.offline
      })
    await failed.model.loadIfNeeded()
    guard case .failed = failed.model.state else {
      return XCTFail("expected the folder to fail, got \(failed.model.state)")
    }
    let levels = [try await level(.root, folders: Self.rootFolders), failed]
    _ = try assertRenderingSnapshot(
      name: "tv-files-move-error", view: sheet(levels), size: viewport)
  }

  func testLongNamesCutInTheMiddleAndThePathFromTheStartMatchesBaseline() async throws {
    let series = PutioFolderRoute(
      id: PutioFileID(rawValue: 60), title: "Blue Lights Complete Series Collection")
    let season = PutioFolderRoute(id: PutioFileID(rawValue: 61), title: "Season 04 (2026)")
    let levels = [
      try await level(.root, folders: [(60, series.title)]),
      try await level(series, folders: [(61, season.title)]),
      try await level(
        season,
        folders: [
          (62, "Blue.Lights.S04.1080p.HDTV.H264-ORGANiC"),
          (63, "Blue Lights S04 Extras and Behind the Scenes"), (64, "Subs"),
          (65, "Season 05 (2027) 2160p WEB-DL DDP5.1 Atmos HDR"),
        ]),
    ]
    let item = Self.file(
      id: 66, parentID: 62, name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv", kind: .video)
    _ = try assertRenderingSnapshot(
      name: "tv-files-move-long", view: sheet(levels, item: item), size: viewport)
  }

  private func sheet(
    _ levels: [TVMoveSheet.Level], item: PutioFileItem = TVMoveSheetTests.item
  ) -> some View {
    TVMoveSheet(
      item: item, levels: levels, load: { _ in throw PutioFolderLoadError.offline },
      continueLoad: nil, loadsOnAppear: false, move: { _ in .closed }, close: {}
    )
    .background(PutioTheme.Colors.background)
  }

  private func level(
    _ route: PutioFolderRoute, folders: [(Int, String)]
  ) async throws -> TVMoveSheet.Level {
    let items = folders.map { id, name in
      Self.file(id: id, parentID: route.id.rawValue, name: name, kind: .folder)
    }
    let contents = PutioFolderContents(folder: nil, items: items)
    let level = TVMoveSheet.Level(
      route: route, model: PutioFolderModel(folderID: route.id) { _ in contents })
    await level.model.loadIfNeeded()
    XCTAssertTrue(level.model.isLoaded)
    return level
  }

  private static let documentaries = PutioFolderRoute(
    id: PutioFileID(rawValue: 30), title: "Documentaries")
  private static let rootFolders = [
    (10, "Big Buck Bunny"), (20, "Blue Lights S04"), (30, "Documentaries"), (40, "Movies"),
    (50, "Music"),
  ]
  private static let documentaryFolders = [(31, "Nature"), (32, "Space"), (33, "True crime")]
  fileprivate static let item = file(id: 11, parentID: 10, name: "Big Buck Bunny.mp4", kind: .video)

  private static func file(
    id: Int, parentID: Int, name: String, kind: PutioFileKind
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: id), parentID: PutioFileID(rawValue: parentID), name: name,
      kind: kind, sizeBytes: 0, createdAt: .distantPast, updatedAt: .distantPast,
      resumePositionSeconds: 0)
  }
}
