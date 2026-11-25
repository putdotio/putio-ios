import Foundation
import XCTest

@testable import PutioCore

@MainActor
private final class SuspendedNextVideoPreflightWait {
  let started = XCTestExpectation(description: "SuspendedNextVideoPreflightWait suspended")
  private(set) var requestedIDs: [PutioFileID] = []
  private var continuation: CheckedContinuation<Void, Never>?

  func wait(for fileID: PutioFileID) async {
    guard !Task.isCancelled else { return }
    requestedIDs.append(fileID)
    await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class NextVideoRecorder {
  var operations: [String] = []
}

@MainActor
final class PutioNextVideoSuccessorTests: XCTestCase {
  private let completedFileID = PutioFileID(rawValue: 411)
  private let nextVideo = PutioNextVideo(
    id: PutioFileID(rawValue: 412),
    parentID: PutioFileID(rawValue: 410),
    name: "Episode 2.mp4"
  )
  private var playableNextVideo: PutioPlayableNextVideo {
    PutioPlayableNextVideo(
      video: nextVideo,
      initialResolution: .ready(
        PutioPlaybackSource(
          url: URL(fileURLWithPath: "/episode-2.m3u8"),
          startFromSeconds: 37
        )
      )
    )
  }

  func testPreparationRejectsSuccessorWhenPlaybackResolutionFails() async {
    let recorder = NextVideoRecorder()

    do {
      _ = try await prepareNextVideo(
        after: completedFileID,
        findNext: { fileID in
          recorder.operations.append("find:\(fileID.rawValue)")
          return self.nextVideo
        },
        waitForPendingReports: { _ in },
        resolve: { fileID in
          recorder.operations.append("resolve:\(fileID.rawValue)")
          throw PutioRuntimeError.notFound
        }
      )
      XCTFail("unplayable successor preparation unexpectedly succeeded")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .notFound)
    }

    XCTAssertEqual(recorder.operations, ["find:411", "resolve:412"])
  }

  func testOfflineSuccessorComesFromTheQueueWhenTheServerLookupFails() async throws {
    let recorder = NextVideoRecorder()
    let local = PutioPlaybackSource(
      url: URL(fileURLWithPath: "/offline/episode-2.mp4"), startFromSeconds: 12)

    let prepared = try await prepareNextVideo(
      after: completedFileID,
      findNext: { fileID in
        recorder.operations.append("find:\(fileID.rawValue)")
        throw PutioRuntimeError.transient
      },
      findOfflineNext: { fileID in
        recorder.operations.append("queue:\(fileID.rawValue)")
        return self.nextVideo
      },
      waitForPendingReports: { fileID in recorder.operations.append("drain:\(fileID.rawValue)") },
      resolve: { fileID in
        recorder.operations.append("resolve:\(fileID.rawValue)")
        return .ready(local)
      }
    )

    XCTAssertEqual(recorder.operations, ["find:411", "queue:411", "drain:412", "resolve:412"])
    XCTAssertEqual(
      prepared, PutioPlayableNextVideo(video: nextVideo, initialResolution: .ready(local)))
  }

  func testServerLookupFailureWithoutAQueuedSuccessorStillFails() async {
    do {
      _ = try await prepareNextVideo(
        after: completedFileID,
        findNext: { _ in throw PutioRuntimeError.transient },
        findOfflineNext: { _ in nil },
        waitForPendingReports: { _ in },
        resolve: { _ in
          XCTFail("nothing to resolve without a successor")
          throw PutioRuntimeError.unknown
        }
      )
      XCTFail("preparation without any successor unexpectedly succeeded")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .transient)
    }
  }

  func testServerAnswerOfNoSuccessorNeverConsultsTheQueue() async throws {
    let prepared = try await prepareNextVideo(
      after: completedFileID,
      findNext: { _ in nil },
      findOfflineNext: { _ in
        XCTFail("a definitive server answer must not fall back to the queue")
        return self.nextVideo
      },
      waitForPendingReports: { _ in },
      resolve: { _ in self.playableNextVideo.initialResolution }
    )

    XCTAssertNil(prepared)
  }

  func testCancelledServerLookupIsNotReplacedByAQueuedSuccessor() async {
    do {
      _ = try await prepareNextVideo(
        after: completedFileID,
        findNext: { _ in throw CancellationError() },
        findOfflineNext: { _ in
          XCTFail("a cancelled lookup must not fall back to the queue")
          return self.nextVideo
        },
        waitForPendingReports: { _ in },
        resolve: { _ in self.playableNextVideo.initialResolution }
      )
      XCTFail("cancelled preparation unexpectedly succeeded")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testPreparationWaitsForSuccessorReportsBeforeResolving() async throws {
    let preflightWait = SuspendedNextVideoPreflightWait()
    let recorder = NextVideoRecorder()
    let preparation = Task {
      try await prepareNextVideo(
        after: completedFileID,
        findNext: { fileID in
          recorder.operations.append("find:\(fileID.rawValue)")
          return self.nextVideo
        },
        waitForPendingReports: { await preflightWait.wait(for: $0) },
        resolve: { fileID in
          recorder.operations.append("resolve:\(fileID.rawValue)")
          return self.playableNextVideo.initialResolution
        }
      )
    }
    defer {
      preparation.cancel()
      preflightWait.resume()
    }
    await fulfillment(of: [preflightWait.started], timeout: 2)
    guard !preflightWait.requestedIDs.isEmpty else { return }

    XCTAssertEqual(preflightWait.requestedIDs, [nextVideo.id])
    XCTAssertEqual(recorder.operations, ["find:411"])

    preflightWait.resume()
    let preparedVideo = try await preparation.value

    XCTAssertEqual(recorder.operations, ["find:411", "resolve:412"])
    XCTAssertEqual(preparedVideo, playableNextVideo)
  }

  func testCancelledPreparationDoesNotResolveAfterSuccessorReportsFinish() async {
    let preflightWait = SuspendedNextVideoPreflightWait()
    let recorder = NextVideoRecorder()
    let preparation = Task {
      try await prepareNextVideo(
        after: completedFileID,
        findNext: { fileID in
          recorder.operations.append("find:\(fileID.rawValue)")
          return self.nextVideo
        },
        waitForPendingReports: { await preflightWait.wait(for: $0) },
        resolve: { fileID in
          recorder.operations.append("resolve:\(fileID.rawValue)")
          return self.playableNextVideo.initialResolution
        }
      )
    }
    defer {
      preparation.cancel()
      preflightWait.resume()
    }
    await fulfillment(of: [preflightWait.started], timeout: 2)
    guard !preflightWait.requestedIDs.isEmpty else { return }

    preparation.cancel()
    preflightWait.resume()

    do {
      _ = try await preparation.value
      XCTFail("cancelled successor preparation unexpectedly resolved")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(recorder.operations, ["find:411"])
  }

  func testDownloadedSuccessorPlaysFromItsLocalSourceWithoutResolving() async throws {
    let local = PutioPlaybackSource(
      url: URL(fileURLWithPath: "/offline/episode-2.mp4"), startFromSeconds: 12)
    var resolvedIDs: [PutioFileID] = []

    let resolution = try await resolveSuccessorSource(
      fileID: nextVideo.id,
      localSource: { fileID in fileID == self.nextVideo.id ? local : nil },
      resolve: { fileID in
        resolvedIDs.append(fileID)
        return self.playableNextVideo.initialResolution
      }
    )

    XCTAssertEqual(resolution, .ready(local))
    XCTAssertEqual(resolvedIDs, [])
  }

  func testSuccessorWithoutADownloadResolvesOnline() async throws {
    var resolvedIDs: [PutioFileID] = []

    let resolution = try await resolveSuccessorSource(
      fileID: nextVideo.id,
      localSource: { _ in nil },
      resolve: { fileID in
        resolvedIDs.append(fileID)
        return self.playableNextVideo.initialResolution
      }
    )

    XCTAssertEqual(resolution, playableNextVideo.initialResolution)
    XCTAssertEqual(resolvedIDs, [nextVideo.id])
  }

  func testPreparedOfflineSuccessorKeepsItsLocalStartPositionAfterReportsDrain() async throws {
    let recorder = NextVideoRecorder()
    let local = PutioPlaybackSource(
      url: URL(fileURLWithPath: "/offline/episode-2.mp4"), startFromSeconds: 12)

    let prepared = try await prepareNextVideo(
      after: completedFileID,
      findNext: { _ in self.nextVideo },
      waitForPendingReports: { fileID in recorder.operations.append("drain:\(fileID.rawValue)") },
      resolve: { fileID in
        recorder.operations.append("resolve:\(fileID.rawValue)")
        return try await resolveSuccessorSource(
          fileID: fileID, localSource: { _ in local },
          resolve: { _ in
            XCTFail("a downloaded successor must not resolve online")
            throw PutioRuntimeError.unknown
          })
      }
    )

    XCTAssertEqual(recorder.operations, ["drain:412", "resolve:412"])
    XCTAssertEqual(
      prepared, PutioPlayableNextVideo(video: nextVideo, initialResolution: .ready(local)))
  }
}
