import Foundation
import XCTest

@testable import PutioDomain

@MainActor
private final class UpNextRecorder {
  var operations: [String] = []
  var countdown: [Int] = []
  var findResults: [Result<PutioNextVideo?, Error>] = []
  var prepareFailures = 0
  var autoplay = true
  weak var model: PutioVideoUpNextModel?
  var onSleep: (@MainActor (PutioVideoUpNextModel) -> Void)?
}

private struct UpNextFailure: Error {}

@MainActor
private final class HeldLookup {
  let started = XCTestExpectation(description: "HeldLookup suspended")
  private(set) var requests = 0
  private var released = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func hold() async {
    requests += 1
    guard !released else { return }
    await withCheckedContinuation {
      continuations.append($0)
      if requests == 1 { started.fulfill() }
    }
  }

  func release() {
    released = true
    for continuation in continuations { continuation.resume() }
    continuations.removeAll()
  }
}

@MainActor
final class PutioVideoUpNextModelTests: XCTestCase {
  private let fileID = PutioFileID(rawValue: 441)
  private let next = PutioNextVideo(
    id: PutioFileID(rawValue: 442), parentID: PutioFileID(rawValue: 440),
    name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv")

  private func playable(_ video: PutioNextVideo) -> PutioPlayableNextVideo {
    PutioPlayableNextVideo(
      video: video,
      initialResolution: .ready(
        PutioPlaybackSource(url: URL(fileURLWithPath: "/442.m3u8"), startFromSeconds: 37)))
  }

  private func model(_ recorder: UpNextRecorder, suggestions: Bool = true)
    -> PutioVideoUpNextModel
  {
    let model = PutioVideoUpNextModel(
      fileID: fileID,
      suggestionsEnabled: suggestions,
      autoplayEnabled: { recorder.autoplay },
      waitForReset: { recorder.operations.append("reset:\($0.rawValue)") },
      find: { fileID in
        recorder.operations.append("find:\(fileID.rawValue)")
        let result =
          recorder.findResults.isEmpty
          ? .success(self.next)
          : recorder.findResults
            .removeFirst()
        return try result.get()
      },
      prepare: { video in
        recorder.operations.append("prepare:\(video.id.rawValue)")
        if recorder.prepareFailures > 0 {
          recorder.prepareFailures -= 1
          throw UpNextFailure()
        }
        return self.playable(video)
      },
      sleep: { duration in
        XCTAssertEqual(duration, .seconds(1))
        guard let model = recorder.model else { return }
        if case .countingDown(_, let seconds) = model.state { recorder.countdown.append(seconds) }
        recorder.onSleep?(model)
        for _ in 0..<5 { await Task.yield() }
      })
    recorder.model = model
    return model
  }

  func testLookUpOffersTheNextVideoAndTheLastVideoOffersNone() async {
    let recorder = UpNextRecorder()
    let offered = model(recorder)
    await offered.lookUp()
    XCTAssertEqual(offered.upcoming, next)

    let lastRecorder = UpNextRecorder()
    lastRecorder.findResults = [.success(nil)]
    let last = model(lastRecorder)
    await last.lookUp()
    await last.playbackEnded()
    XCTAssertNil(last.upcoming)
    XCTAssertEqual(last.state, .idle)
    XCTAssertEqual(lastRecorder.operations, ["find:441", "reset:441"])
  }

  func testDisabledSuggestionsNeverLookUpOrCountDown() async {
    let recorder = UpNextRecorder()
    let model = model(recorder, suggestions: false)
    await model.lookUp()
    await model.playbackEnded()
    XCTAssertNil(model.upcoming)
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(recorder.operations, ["reset:441"])
  }

  func testAutoplayCountsDownFromTenThenPlaysTheLookedUpVideo() async {
    let recorder = UpNextRecorder()
    let model = model(recorder)
    await model.lookUp()
    await model.playbackEnded()
    XCTAssertEqual(recorder.countdown, [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
    XCTAssertEqual(model.state, .playing(playable(next)))
    XCTAssertEqual(recorder.operations, ["find:441", "reset:441", "prepare:442"])
  }

  func testAutoplayOffKeepsTheFinishedVideoWithTheChip() async {
    let recorder = UpNextRecorder()
    recorder.autoplay = false
    let model = model(recorder)
    await model.lookUp()
    await model.playbackEnded()
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(model.upcoming, next)
    XCTAssertEqual(recorder.operations, ["find:441", "reset:441"])
  }

  func testAutoplayOffRetriesAFailedLookupForTheChip() async {
    let recorder = UpNextRecorder()
    recorder.autoplay = false
    recorder.findResults = [.failure(UpNextFailure())]
    let model = model(recorder)
    await model.lookUp()
    XCTAssertNil(model.upcoming)
    await model.playbackEnded()
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(model.upcoming, next)
    XCTAssertEqual(recorder.operations, ["find:441", "reset:441", "find:441"])
  }

  func testALookupThatKeepsFailingIsNotAnEmptyFolder() async {
    let recorder = UpNextRecorder()
    recorder.autoplay = false
    recorder.findResults = [.failure(UpNextFailure()), .failure(UpNextFailure()), .success(nil)]
    let model = model(recorder)
    await model.lookUp()
    XCTAssertTrue(model.lookupFailed)
    await model.playbackEnded()
    XCTAssertEqual(model.state, .idle)
    XCTAssertNil(model.upcoming)
    XCTAssertTrue(model.lookupFailed, "a failed retry still isn't a confirmed last video")
    await model.retry()
    XCTAssertNil(model.upcoming)
    XCTAssertFalse(model.lookupFailed, "an empty answer confirms the last video")
  }

  func testCancelDuringTheCountdownKeepsTheFinishedVideo() async {
    let recorder = UpNextRecorder()
    let model = model(recorder)
    recorder.onSleep = { model in
      if recorder.countdown.count == 3 { model.cancel() }
    }
    await model.lookUp()
    await model.playbackEnded()
    XCTAssertEqual(recorder.countdown, [10, 9, 8])
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(model.upcoming, next)
    XCTAssertFalse(recorder.operations.contains("prepare:442"))
  }

  func testPlayNextDuringTheCountdownPlaysAtOnce() async {
    let recorder = UpNextRecorder()
    let model = model(recorder)
    var played: Task<Void, Never>?
    recorder.onSleep = { model in
      if recorder.countdown.count == 2 { played = Task { await model.playNext() } }
    }
    await model.lookUp()
    await model.playbackEnded()
    await played?.value
    XCTAssertEqual(recorder.countdown, [10, 9])
    XCTAssertEqual(model.state, .playing(playable(next)))
    XCTAssertEqual(recorder.operations.filter { $0.hasPrefix("prepare") }, ["prepare:442"])
  }

  func testChipPlaysTheNextVideoWhileTheCurrentOnePlays() async {
    let recorder = UpNextRecorder()
    recorder.autoplay = false
    let model = model(recorder)
    await model.lookUp()
    await model.playNext()
    XCTAssertEqual(model.state, .playing(playable(next)))
    XCTAssertEqual(recorder.operations, ["find:441", "prepare:442"])
    XCTAssertTrue(recorder.countdown.isEmpty)
  }

  func testFailedLookupAtTheEndFailsAndTryAgainCountsDown() async {
    let recorder = UpNextRecorder()
    recorder.findResults = [.failure(UpNextFailure()), .failure(UpNextFailure())]
    let model = model(recorder)
    await model.lookUp()
    XCTAssertNil(model.upcoming)
    await model.playbackEnded()
    XCTAssertEqual(model.state, .failed)
    await model.retry()
    XCTAssertEqual(recorder.countdown.first, 10)
    XCTAssertEqual(model.state, .playing(playable(next)))
  }

  func testFailedChipPlayCancelsBackToTheChip() async {
    let recorder = UpNextRecorder()
    recorder.prepareFailures = 2
    let model = model(recorder)
    await model.lookUp()
    await model.playNext()
    XCTAssertEqual(model.state, .failed)
    await model.retry()
    XCTAssertEqual(model.state, .failed)
    XCTAssertTrue(recorder.countdown.isEmpty, "Try again after a chip tap never counts down")
    model.cancel()
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(model.upcoming, next)
  }

  func testTheEndAwaitsTheLookupInFlightInsteadOfFindingAgain() async {
    let held = HeldLookup()
    let next = next
    let model = PutioVideoUpNextModel(
      fileID: fileID,
      autoplayEnabled: { true },
      countdown: .zero,
      waitForReset: { _ in },
      find: { _ in
        await held.hold()
        return next
      },
      prepare: { self.playable($0) })
    let lookup = Task { await model.lookUp() }
    await fulfillment(of: [held.started], timeout: 1)
    let ended = Task { await model.playbackEnded() }
    for _ in 0..<5 { await Task.yield() }
    held.release()
    await lookup.value
    await ended.value
    XCTAssertEqual(held.requests, 1)
    XCTAssertEqual(model.state, .playing(playable(next)))
  }
}
