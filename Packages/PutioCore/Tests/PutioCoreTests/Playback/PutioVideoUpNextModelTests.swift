import Foundation
import XCTest

@testable import PutioCore

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
    XCTAssertEqual(recorder.operations, ["find:441", "reset:441", "prepare:442"])
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
}
