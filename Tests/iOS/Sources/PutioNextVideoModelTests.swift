import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class SuspendedNextVideoLoad {
  private(set) var requestedIDs: [PutioFileID] = []
  private var continuation: CheckedContinuation<PutioPlayableNextVideo?, Never>?

  func load(_ fileID: PutioFileID) async -> PutioPlayableNextVideo? {
    requestedIDs.append(fileID)
    return await withCheckedContinuation { continuation = $0 }
  }

  func resume(returning video: PutioPlayableNextVideo?) {
    continuation?.resume(returning: video)
    continuation = nil
  }
}

@MainActor
private final class SuspendedNextVideoSleep {
  private(set) var durations: [Duration] = []
  private var continuation: CheckedContinuation<Void, Never>?

  func sleep(for duration: Duration) async {
    durations.append(duration)
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class SuspendedFirstResetWait {
  private(set) var requests = 0
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    requests += 1
    guard requests == 1 else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class SuspendedNextVideoPreflightWait {
  private(set) var requestedIDs: [PutioFileID] = []
  private var continuation: CheckedContinuation<Void, Never>?

  func wait(for fileID: PutioFileID) async {
    requestedIDs.append(fileID)
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class NextVideoRecorder {
  var operations: [String] = []
  var durations: [Duration] = []
}

@MainActor
final class PutioNextVideoModelTests: XCTestCase {
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

  func testPlaybackEndWaitsForResetBeforeLoadingSuccessor() async {
    let recorder = NextVideoRecorder()
    let model = PutioNextVideoModel(
      autoplayEnabled: false,
      waitForReset: { fileID in
        recorder.operations.append("reset:\(fileID.rawValue)")
      },
      loadNext: { fileID in
        recorder.operations.append("load:\(fileID.rawValue)")
        return self.playableNextVideo
      }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(recorder.operations, ["reset:411", "load:411"])
    XCTAssertEqual(model.state, .available(playableNextVideo))
  }

  func testDisabledSuggestionsResetWithoutLoadingSuccessor() async {
    let recorder = NextVideoRecorder()
    let model = PutioNextVideoModel(
      suggestionsEnabled: false,
      autoplayEnabled: true,
      waitForReset: { fileID in
        recorder.operations.append("reset:\(fileID.rawValue)")
      },
      loadNext: { fileID in
        recorder.operations.append("load:\(fileID.rawValue)")
        return self.playableNextVideo
      }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(recorder.operations, ["reset:411"])
    XCTAssertEqual(model.state, .unavailable)
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
    while preflightWait.requestedIDs.isEmpty {
      await Task.yield()
    }

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
    while preflightWait.requestedIDs.isEmpty {
      await Task.yield()
    }

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

  func testEnabledAutoplayTransitionsAfterTheBoundedDelay() async {
    let recorder = NextVideoRecorder()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      autoplayDelay: .seconds(30),
      waitForReset: { _ in },
      loadNext: { _ in self.playableNextVideo },
      sleep: { duration in recorder.durations.append(duration) }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(recorder.durations, [.seconds(10)])
    XCTAssertEqual(model.state, .playing(playableNextVideo))
  }

  func testAutoplayDelayDoesNotGoBelowZero() async {
    let recorder = NextVideoRecorder()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      autoplayDelay: .seconds(-1),
      waitForReset: { _ in },
      loadNext: { _ in self.playableNextVideo },
      sleep: { duration in recorder.durations.append(duration) }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(recorder.durations, [.zero])
    XCTAssertEqual(model.state, .playing(playableNextVideo))
  }

  func testDisabledAutoplayKeepsManualPlayNextAvailable() async {
    let model = makeModel(autoplayEnabled: false)

    await model.playbackEnded(completedFileID: completedFileID)
    XCTAssertEqual(model.state, .available(playableNextVideo))

    model.playNext()

    XCTAssertEqual(model.state, .playing(playableNextVideo))
  }

  func testMissingSuccessorEndsUnavailable() async {
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { _ in nil }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(model.state, .unavailable)
  }

  func testSuccessorErrorEndsUnavailable() async {
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { _ in throw PutioRuntimeError.transient }
    )

    await model.playbackEnded(completedFileID: completedFileID)

    XCTAssertEqual(model.state, .unavailable)
  }

  func testCancelDuringLookupRejectsTheStaleCompletion() async {
    let load = SuspendedNextVideoLoad()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { await load.load($0) }
    )
    let transition = Task { await model.playbackEnded(completedFileID: completedFileID) }
    while load.requestedIDs.isEmpty {
      await Task.yield()
    }

    model.cancel()
    load.resume(returning: playableNextVideo)
    await transition.value

    XCTAssertEqual(model.state, .cancelled)
  }

  func testCancelDuringAutoplayDelayRejectsTheStaleCompletion() async {
    let sleep = SuspendedNextVideoSleep()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { _ in self.playableNextVideo },
      sleep: { await sleep.sleep(for: $0) }
    )
    let transition = Task { await model.playbackEnded(completedFileID: completedFileID) }
    while sleep.durations.isEmpty {
      await Task.yield()
    }

    XCTAssertEqual(model.state, .available(playableNextVideo))
    model.cancel()
    sleep.resume()
    await transition.value

    XCTAssertEqual(model.state, .cancelled)
  }

  func testManualPlayDuringAutoplayDelayWinsOverTheScheduledTransition() async {
    let sleep = SuspendedNextVideoSleep()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { _ in self.playableNextVideo },
      sleep: { await sleep.sleep(for: $0) }
    )
    let transition = Task { await model.playbackEnded(completedFileID: completedFileID) }
    while sleep.durations.isEmpty {
      await Task.yield()
    }

    model.playNext()
    sleep.resume()
    await transition.value

    XCTAssertEqual(model.state, .playing(playableNextVideo))
  }

  func testTaskCancellationCannotReplaceCancelledState() async {
    let load = SuspendedNextVideoLoad()
    let model = PutioNextVideoModel(
      autoplayEnabled: true,
      waitForReset: { _ in },
      loadNext: { await load.load($0) }
    )
    let transition = Task { await model.playbackEnded(completedFileID: completedFileID) }
    while load.requestedIDs.isEmpty {
      await Task.yield()
    }

    transition.cancel()
    load.resume(returning: nil)
    await transition.value

    XCTAssertEqual(model.state, .cancelled)
  }

  func testNewPlaybackEndRejectsAnOlderResetCompletion() async {
    let resetWait = SuspendedFirstResetWait()
    let staleVideo = PutioPlayableNextVideo(
      video: PutioNextVideo(
        id: PutioFileID(rawValue: 413),
        parentID: PutioFileID(rawValue: 410),
        name: "Stale episode.mp4"
      ),
      initialResolution: .conversionRequired
    )
    let model = PutioNextVideoModel(
      autoplayEnabled: false,
      waitForReset: { _ in await resetWait.wait() },
      loadNext: { fileID in
        fileID == self.completedFileID ? staleVideo : self.playableNextVideo
      }
    )
    let firstTransition = Task {
      await model.playbackEnded(completedFileID: completedFileID)
    }
    while resetWait.requests == 0 {
      await Task.yield()
    }

    await model.playbackEnded(completedFileID: PutioFileID(rawValue: 499))
    XCTAssertEqual(model.state, .available(playableNextVideo))

    resetWait.resume()
    await firstTransition.value

    XCTAssertEqual(model.state, .available(playableNextVideo))
  }

  private func makeModel(autoplayEnabled: Bool) -> PutioNextVideoModel {
    PutioNextVideoModel(
      autoplayEnabled: autoplayEnabled,
      waitForReset: { _ in },
      loadNext: { _ in self.playableNextVideo }
    )
  }
}
