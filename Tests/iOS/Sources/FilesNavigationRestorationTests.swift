import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FilesNavigationRestorationTests: XCTestCase {
  func testRelaunchRestoresAccountPathWithCurrentTitles() async throws {
    let defaults = try isolatedDefaults()
    let store = PutioFilesNavigationRestoration(defaults: defaults)
    store.save(path: [route(1), route(2)], for: 10)
    store.save(path: [route(3)], for: 20)

    let relaunched = PutioFilesNavigationRestoration(defaults: defaults)
    let restored = await relaunched.restore(accountID: 10) { id in
      self.contents(id.rawValue, parent: id.rawValue == 1 ? 0 : 1, title: "Current")
    }
    XCTAssertEqual(restored.map(\.id.rawValue), [1, 2])
    XCTAssertEqual(restored.map(\.title), ["Current", "Current"])
    let other = await relaunched.restore(accountID: 20) { _ in self.contents(3) }
    XCTAssertEqual(other.map(\.id.rawValue), [3])
    let unknown = await relaunched.restore(accountID: 30) { _ in
      XCTFail("An unknown account must not load another account's path")
      throw PutioRuntimeError.unknown
    }
    XCTAssertTrue(unknown.isEmpty)
  }

  func testDeletedFolderTruncatesPathAndPersistsSurvivingAncestor() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    store.save(path: [route(1), route(2), route(3)], for: 10)
    let restored = await store.restore(accountID: 10) { id in
      if id.rawValue == 1 { return self.contents(1) }
      throw PutioRuntimeError.notFound
    }
    XCTAssertEqual(restored.map(\.id.rawValue), [1])
    let nextLaunch = await store.restore(accountID: 10) { id in
      XCTAssertEqual(id.rawValue, 1)
      return self.contents(1)
    }
    XCTAssertEqual(nextLaunch.map(\.id.rawValue), [1])
  }

  func testMovedFolderTruncatesDisconnectedAncestry() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    store.save(path: [route(1), route(2)], for: 10)
    let restored = await store.restore(accountID: 10) { id in
      self.contents(id.rawValue, parent: id.rawValue == 1 ? 0 : 99)
    }
    XCTAssertEqual(restored.map(\.id.rawValue), [1])
  }

  func testTemporaryFailuresPreservePathForRetry() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    let path = [route(1), route(2)]
    store.save(path: path, for: 10)
    for error in [PutioRuntimeError.transient, .rateLimited, .sessionExpired, .invalidResponse] {
      let restored = await store.restore(accountID: 10) { _ in throw error }
      XCTAssertEqual(restored, path)
    }
    let retried = await store.restore(accountID: 10) { id in
      self.contents(id.rawValue, parent: id.rawValue == 1 ? 0 : 1)
    }
    XCTAssertEqual(retried, path)
  }

  func testIncompleteOrMismatchedResponsesDoNotEraseSavedPath() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    let path = [route(1)]
    store.save(path: path, for: 10)
    let incomplete = await store.restore(accountID: 10) { _ in
      PutioFolderContents(folder: nil, items: [])
    }
    XCTAssertEqual(incomplete, path)
    let mismatched = await store.restore(accountID: 10) { _ in self.contents(99) }
    XCTAssertEqual(mismatched, path)
    let retried = await store.restore(accountID: 10) { _ in self.contents(1) }
    XCTAssertEqual(retried, path)
  }

  func testSignOutClearsOnlyItsAccountAndCannotBeUndoneByPendingRestore() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    store.save(path: [route(1)], for: 10)
    store.save(path: [route(2)], for: 20)
    let restored = await store.restore(accountID: 10) { _ in
      store.clear(accountID: 10)
      return self.contents(1)
    }
    XCTAssertTrue(restored.isEmpty)
    let signedOut = await store.restore(accountID: 10) { _ in
      XCTFail("Cleared navigation must not reload")
      throw PutioRuntimeError.unknown
    }
    XCTAssertTrue(signedOut.isEmpty)
    let other = await store.restore(accountID: 20) { _ in self.contents(2) }
    XCTAssertEqual(other.map(\.id.rawValue), [2])
  }

  func testNewNavigationWinsOverPendingRestore() async throws {
    let store = PutioFilesNavigationRestoration(defaults: try isolatedDefaults())
    store.save(path: [route(1)], for: 10)
    let stale = await store.restore(accountID: 10) { _ in
      store.save(path: [self.route(2)], for: 10)
      return self.contents(1)
    }
    XCTAssertTrue(stale.isEmpty)
    let latest = await store.restore(accountID: 10) { _ in self.contents(2) }
    XCTAssertEqual(latest.map(\.id.rawValue), [2])
  }

  func testMalformedSnapshotsAndInvalidRoutesAreRejectedWithoutRequests() async throws {
    let defaults = try isolatedDefaults()
    let store = PutioFilesNavigationRestoration(defaults: defaults)
    let snapshots = [
      "not json",
      #"{"version":2,"folders":[]}"#,
      #"{"version":1,"folders":[{"id":0,"title":"Root"}]}"#,
      #"{"version":1,"folders":[{"id":-1,"title":"Invalid"}]}"#,
      #"{"version":1,"folders":[{"id":1,"title":"One"},{"id":1,"title":"Again"}]}"#,
      #"{"version":1,"folders":[{"id":1,"title":""}]}"#,
    ]
    for snapshot in snapshots {
      defaults.set(Data(snapshot.utf8), forKey: "putio.files.navigation.10")
      let restored = await store.restore(accountID: 10) { _ in
        XCTFail("Malformed paths must not reach the API")
        throw PutioRuntimeError.unknown
      }
      XCTAssertTrue(restored.isEmpty)
      XCTAssertNil(defaults.data(forKey: "putio.files.navigation.10"))
    }
    for path in [[route(0)], [route(-1)], [route(1), route(1)]] {
      store.save(path: path, for: 10)
      XCTAssertNil(defaults.data(forKey: "putio.files.navigation.10"))
    }
  }

  private func isolatedDefaults() throws -> UserDefaults {
    let suite = "FilesNavigationRestorationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return defaults
  }

  private func route(_ id: Int) -> PutioFolderRoute {
    PutioFolderRoute(id: PutioFileID(rawValue: id), title: "Folder \(id)")
  }

  private func contents(_ id: Int, parent: Int = 0, title: String = "Folder") -> PutioFolderContents
  {
    PutioFolderContents(
      folder: PutioFileItem(
        id: PutioFileID(rawValue: id), parentID: PutioFileID(rawValue: parent), name: title,
        kind: .folder, sizeBytes: 0, createdAt: .distantPast, updatedAt: .distantPast,
        resumePositionSeconds: 0), items: [])
  }
}
