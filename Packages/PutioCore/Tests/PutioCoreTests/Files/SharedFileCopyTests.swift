import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class SharedFileCopyTests: XCTestCase {
  private let destination = PutioFolderRoute(id: PutioFileID(rawValue: 30), title: "Movies")

  func testCopyStartsInTheDestinationAndChecksUntilDone() async {
    let calls = Calls()
    let model = model(
      start: { fileID, parentID in
        calls.started.append([fileID.rawValue, parentID.rawValue])
        return 91
      },
      check: { copyID in
        calls.checked.append(copyID)
        return calls.checked.count < 3 ? .running : .done
      })
    let result = await model.copy(sharedFile, to: destination)
    XCTAssertEqual(result?.outcome, .copied)
    XCTAssertEqual(result?.name, "Tears.of.Steel.2012.mkv")
    XCTAssertEqual(result?.destination.title, "Movies")
    XCTAssertEqual(calls.started, [[7, 30]])
    XCTAssertEqual(calls.checked, [91, 91, 91])
    XCTAssertFalse(model.isRunning)
  }

  func testACopyThatNeverSettlesIsUnconfirmedAfterTheLastCheck() async {
    let calls = Calls()
    let model = model(
      start: { _, _ in 91 },
      check: { _ in
        calls.checked.append(0)
        return .running
      })
    let result = await model.copy(sharedFile, to: destination)
    XCTAssertEqual(result?.outcome, .unconfirmed)
    XCTAssertEqual(calls.checked.count, PutioSharedFileCopyModel.maxChecks)
  }

  func testStartFailuresMapToTheirMessages() async {
    let cases: [(Error, PutioSharedFileCopyOutcome)] = [
      (PutioSharedFileCopyRefusal.concurrentLimit, .concurrentLimit),
      (PutioSharedFileCopyRefusal.tooManyFiles, .tooManyFiles),
      (PutioSharedFileCopyRefusal.rejected, .failed),
      (PutioRuntimeError.rateLimited, .failed),
      (PutioRuntimeError.transient, .unconfirmed),
      (PutioRuntimeError.invalidResponse, .unconfirmed),
    ]
    for (error, expected) in cases {
      let model = model(start: { _, _ in throw error }, check: { _ in .done })
      let result = await model.copy(sharedFile, to: destination)
      XCTAssertEqual(result?.outcome, expected, "\(error)")
    }
  }

  func testAFailedCheckIsUnconfirmedAndAnErrorStatusFails() async {
    let lost = model(start: { _, _ in 91 }, check: { _ in throw PutioRuntimeError.transient })
    let lostResult = await lost.copy(sharedFile, to: destination)
    XCTAssertEqual(lostResult?.outcome, .unconfirmed)
    let failed = model(start: { _, _ in 91 }, check: { _ in .failed })
    let failedResult = await failed.copy(sharedFile, to: destination)
    XCTAssertEqual(failedResult?.outcome, .failed)
  }

  func testASecondCopyCannotStartWhileOneRuns() async {
    let gate = AsyncStream<Void>.makeStream()
    let calls = Calls()
    let model = model(
      start: { _, _ in
        calls.started.append([])
        for await _ in gate.stream { break }
        return 91
      },
      check: { _ in .done })
    let first = Task { await model.copy(sharedFile, to: destination) }
    while calls.started.isEmpty { await Task.yield() }
    XCTAssertTrue(model.isRunning)
    let second = await model.copy(sharedFile, to: destination)
    XCTAssertNil(second)
    gate.continuation.yield()
    let firstResult = await first.value
    XCTAssertEqual(firstResult?.outcome, .copied)
    XCTAssertEqual(calls.started.count, 1)
  }

  func testLeavingStopsTheChecksButNotTheStart() async {
    let gate = AsyncStream<Void>.makeStream()
    let calls = Calls()
    let model = model(
      start: { _, _ in
        for await _ in gate.stream { break }
        calls.started.append([])
        return 91
      },
      check: { copyID in
        calls.checked.append(copyID)
        return .running
      })
    let copy = Task { await model.copy(sharedFile, to: destination) }
    while !model.isRunning { await Task.yield() }
    copy.cancel()
    gate.continuation.yield()
    let result = await copy.value
    XCTAssertNil(result)
    XCTAssertEqual(calls.started.count, 1, "cancelling abandoned the start request")
    XCTAssertEqual(calls.checked, [])
    XCTAssertFalse(model.isRunning)
  }

  func testOnlySharedFilesCopy() async {
    let model = model(start: { _, _ in 91 }, check: { _ in .done })
    let own = await model.copy(item(shared: false, kind: .video), to: destination)
    XCTAssertNil(own)
    let folder = await model.copy(item(shared: true, kind: .folder), to: destination)
    XCTAssertNil(folder)
  }

  private var sharedFile: PutioFileItem { item(shared: true, kind: .video) }

  private func item(shared: Bool, kind: PutioFileKind) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: 7), parentID: PutioFileID(rawValue: 5),
      name: "Tears.of.Steel.2012.mkv", kind: kind, sizeBytes: 1, createdAt: .distantPast,
      updatedAt: .distantPast, resumePositionSeconds: 0, isShared: shared)
  }

  private func model(
    start: @escaping @MainActor @Sendable (PutioFileID, PutioFileID) async throws -> Int,
    check: @escaping @MainActor @Sendable (Int) async throws -> PutioSharedFileCopyProgress
  ) -> PutioSharedFileCopyModel {
    PutioSharedFileCopyModel(
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in },
        deleteFile: { _ in },
        copySharedFile: start,
        sharedFileCopyProgress: check),
      sleep: { _ in try Task.checkCancellation() })
  }
}

@MainActor
private final class Calls: @unchecked Sendable {
  var started: [[Int]] = []
  var checked: [Int] = []
}
