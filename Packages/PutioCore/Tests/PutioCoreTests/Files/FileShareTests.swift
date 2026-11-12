import Foundation
import XCTest

@testable import PutioCore

final class FileShareTests: XCTestCase {
  func testStagedShareIsAFileURLThatDiscardRemoves() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data("poster".utf8)

    let shared = try await PutioSharedFile.stage(bytes, named: "a/b.png", in: directory)

    XCTAssertTrue(shared.url.isFileURL)
    XCTAssertTrue(shared.isTemporary)
    XCTAssertEqual(shared.url.lastPathComponent, "a:b.png")
    XCTAssertEqual(try Data(contentsOf: shared.url), bytes)
    shared.discard()
    XCTAssertFalse(FileManager.default.fileExists(atPath: shared.url.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: shared.url.deletingLastPathComponent().path))
  }

  func testOnlyLocalURLsCanBeShared() throws {
    let api = try XCTUnwrap(URL(string: "https://api.put.io/v2/files/1/download"))
    XCTAssertNil(PutioSharedFile(local: api))
    let local = try XCTUnwrap(PutioSharedFile(local: URL(fileURLWithPath: "/tmp/movie.movpkg")))
    XCTAssertFalse(local.isTemporary)
  }

  func testAFailedWriteLeavesNoStagedFolder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    struct WriteFailed: Error {}

    await assertThrowsAsync {
      try await PutioSharedFile.stage(named: "Movie.mp4", in: directory) { _ in throw WriteFailed()
      }
    }

    let staged = try FileManager.default.contentsOfDirectory(
      atPath: directory.appending(path: "FileShare").path)
    XCTAssertEqual(staged, [])
  }

  func testPackagesExportUnderTheFileNameWithTheExportExtension() throws {
    let package = try XCTUnwrap(
      PutioSharedFile(local: URL(fileURLWithPath: "/tmp/0-1.movpkg", isDirectory: true)))
    XCTAssertTrue(package.isPackage)
    XCTAssertEqual(
      PutioSharedFile.exportName("Blue.Lights.S04E02.mkv", pathExtension: "mp4"),
      "Blue.Lights.S04E02.mp4")
    XCTAssertEqual(
      PutioSharedFile.exportName("Harness Track.m4a", pathExtension: "m4a"), "Harness Track.m4a")
    XCTAssertEqual(PutioSharedFile.exportName("AC/DC", pathExtension: "m4a"), "AC:DC.m4a")
  }

  private func assertThrowsAsync(
    _ body: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await body()
      XCTFail("no error thrown", file: file, line: line)
    } catch {}
  }

  func testDiscardKeepsADownloadedFile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("kept".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    try XCTUnwrap(PutioSharedFile(local: file)).discard()

    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

  func testSourcePrefersTheDownloadAndFetchesOnlyPreviewKinds() {
    func item(_ kind: PutioFileKind, size: Int64 = 1) -> PutioFileItem {
      PutioFileItem(
        id: PutioFileID(rawValue: 9), parentID: .root, name: "Item", kind: kind,
        sizeBytes: size, createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: 0)
    }
    XCTAssertEqual(PutioFileShareSource(item: item(.image), isDownloaded: true), .downloaded)
    guard case .fetch(let route) = PutioFileShareSource(item: item(.pdf), isDownloaded: false)
    else { return XCTFail("a PDF under the cap is fetched") }
    XCTAssertEqual(route.kind, .pdf)
    XCTAssertNil(PutioFileShareSource(item: item(.video), isDownloaded: false))
    XCTAssertNil(
      PutioFileShareSource(
        item: item(.image, size: PutioPreviewRoute.maximumBytes + 1), isDownloaded: true))
    XCTAssertTrue(PutioFileShareSource.dependsOnDownload(item(.audio)))
    XCTAssertFalse(PutioFileShareSource.dependsOnDownload(item(.image)))
    XCTAssertFalse(
      PutioFileShareSource.dependsOnDownload(item(.video, size: PutioPreviewRoute.maximumBytes + 1))
    )
  }
}
