import XCTest

@testable import PutioCore

final class PutioDownloadPresentationTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  private func presentation(_ state: PutioDownloadState) -> PutioDownloadPresentation {
    PutioDownloadPresentation(state, locale: english)
  }

  private func statusLine(_ state: PutioDownloadState) -> [String] {
    presentation(state).statusLine.map(\.text)
  }

  func testIdleRowKeepsItsDetailsAndHasNoControl() {
    let idle = presentation(.idle)
    XCTAssertEqual(idle.statusLine, [])
    XCTAssertEqual(idle.ring, .hidden)
    XCTAssertNil(idle.action)
    XCTAssertFalse(idle.dimsRow)
  }

  func testDownloadingShowsBytesAndPercentWithAYellowPauseRing() {
    let state = PutioDownloadState.downloading(
      receivedBytes: 1_400_000_000, totalBytes: 3_300_000_000)
    XCTAssertEqual(statusLine(state), ["1.4 of 3.3 GB", "42%"])
    let result = presentation(state)
    XCTAssertEqual(
      result.ring, .progress(1_400_000_000.0 / 3_300_000_000.0, isActive: true, glyph: .pause))
    XCTAssertEqual(result.action, .pause)
    XCTAssertEqual(result.tone, .secondary)
  }

  func testConvertingShowsPercentWithAYellowPauseRing() {
    let state = PutioDownloadState.converting(progress: 0.12)
    XCTAssertEqual(statusLine(state), ["Converting", "12%"])
    XCTAssertEqual(presentation(state).ring, .progress(0.12, isActive: true, glyph: .pause))
    XCTAssertEqual(presentation(state).action, .pause)
  }

  func testPausedShowsBytesWithAGreyPlayRingThatResumes() {
    let state = PutioDownloadState.paused(receivedBytes: 900_000_000, totalBytes: 3_400_000_000)
    XCTAssertEqual(statusLine(state), ["Paused", "0.9 of 3.4 GB"])
    XCTAssertEqual(
      presentation(state).ring,
      .progress(900_000_000.0 / 3_400_000_000.0, isActive: false, glyph: .play))
    XCTAssertEqual(presentation(state).action, .resume)
  }

  func testWaitingWithBytesShowsAGreyPauseRing() {
    let network = PutioDownloadState.waiting(
      .network, receivedBytes: 1_400_000_000, totalBytes: 3_300_000_000)
    XCTAssertEqual(statusLine(network), ["Waiting for network", "1.4 of 3.3 GB"])
    XCTAssertEqual(
      presentation(network).ring,
      .progress(1_400_000_000.0 / 3_300_000_000.0, isActive: false, glyph: .pause))
    XCTAssertEqual(presentation(network).action, .pause)

    let storage = PutioDownloadState.waiting(
      .storage, receivedBytes: 200_000_000, totalBytes: 3_400_000_000)
    XCTAssertEqual(statusLine(storage), ["Waiting for storage", "0.2 of 3.4 GB"])
    XCTAssertEqual(
      presentation(storage).ring,
      .progress(200_000_000.0 / 3_400_000_000.0, isActive: false, glyph: .pause))
  }

  func testWaitingWithNothingDownloadedShowsADashedRingThatCancels() {
    for (wait, text) in [
      (PutioDownloadWait.network, "Waiting for network"), (.storage, "Waiting for storage"),
    ] {
      let state = PutioDownloadState.waiting(wait, receivedBytes: 0, totalBytes: 3_300_000_000)
      XCTAssertEqual(statusLine(state), [text])
      XCTAssertEqual(presentation(state).ring, .dashed(glyph: nil))
      XCTAssertEqual(presentation(state).action, .cancel)
    }
  }

  func testQueuedNamesItsPlaceInLineWithADashedStopRing() {
    let state = PutioDownloadState.queued(position: 1)
    XCTAssertEqual(statusLine(state), ["Queued · #1 in line"])
    XCTAssertEqual(presentation(state).ring, .dashed(glyph: .stop))
    XCTAssertEqual(presentation(state).action, .cancel)
  }

  func testRemovingDimsTheRowWithoutAControl() {
    let removing = presentation(.removing)
    XCTAssertEqual(removing.statusLine.map(\.text), ["Removing from this iPhone…"])
    XCTAssertEqual(removing.ring, .hidden)
    XCTAssertNil(removing.action)
    XCTAssertTrue(removing.dimsRow)
  }

  func testMissingAndFailedReadRedAndOfferTheirAction() {
    let missing = presentation(.missing)
    XCTAssertEqual(missing.statusLine.map(\.text), ["No longer on this iPhone"])
    XCTAssertEqual(missing.tone, .destructive)
    XCTAssertEqual(missing.ring, .glyph(.again))
    XCTAssertEqual(missing.action, .downloadAgain)

    let failed = presentation(.failed(reason: "Connection lost"))
    XCTAssertEqual(failed.statusLine.map(\.text), ["Connection lost"])
    XCTAssertEqual(failed.tone, .destructive)
    XCTAssertEqual(failed.ring, .glyph(.again))
    XCTAssertEqual(failed.action, .retry)
  }

  func testActionTitlesMatchTheBoards() {
    XCTAssertEqual(
      [.pause, .resume, .cancel, .retry, .downloadAgain].map {
        PutioDownloadPresentation.actionTitle($0, locale: english)
      },
      ["Pause download", "Resume download", "Cancel download", "Retry download", "Download again"]
    )
  }
}
