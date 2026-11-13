import XCTest

@testable import PutioCore

final class PutioVideoTransportTests: XCTestCase {
  func testTimelineReadsLikeTheBoard() {
    let timeline = PutioVideoTimeline(elapsedSeconds: 1_122, durationSeconds: 2_989)

    XCTAssertEqual(timeline.elapsedText, "18:42")
    XCTAssertEqual(timeline.remainingText, "-31:07")
    XCTAssertEqual(
      PutioVideoTimeline(elapsedSeconds: 1_122.6, durationSeconds: 2_989).remainingText, "-31:07",
      "elapsed and remaining do not add up to the duration")
    XCTAssertEqual(PutioVideoTimeline.clock(3_723), "1:02:03")
    XCTAssertEqual(
      PutioVideoTimeline(elapsedSeconds: 5, durationSeconds: nil).remainingText, "--:--")
    XCTAssertEqual(
      PutioVideoTimeline(elapsedSeconds: 5, durationSeconds: .nan).durationSeconds, nil)
  }

  func testSkipsStayInsideTheVideo() {
    let timeline = PutioVideoTimeline(elapsedSeconds: 4, durationSeconds: 590)

    XCTAssertEqual(timeline.target(skippingBy: -PutioVideoTimeline.skipInterval), 0)
    XCTAssertEqual(timeline.target(skippingBy: PutioVideoTimeline.skipInterval), 14)
    XCTAssertEqual(
      PutioVideoTimeline(elapsedSeconds: 585, durationSeconds: 590).target(skippingBy: 10), 590)
  }

  func testTicksBeforeASeekLandsKeepTheTarget() {
    var playhead = PutioVideoPlayhead()
    playhead.observed(elapsedSeconds: 50, durationSeconds: 600)

    let first = playhead.seekStarted(to: playhead.timeline.target(skippingBy: 10))
    playhead.observed(elapsedSeconds: 50.25, durationSeconds: 600)
    XCTAssertEqual(playhead.timeline.elapsedSeconds, 60, "a tick before the seek landed moved back")

    let second = playhead.seekStarted(to: playhead.timeline.target(skippingBy: 10))
    XCTAssertEqual(playhead.timeline.elapsedSeconds, 70, "a second skip started from a stale time")
    playhead.seekFinished(first)
    playhead.observed(elapsedSeconds: 60, durationSeconds: 600)
    XCTAssertEqual(playhead.timeline.elapsedSeconds, 70, "an earlier seek released a later one")

    playhead.seekFinished(second)
    playhead.observed(elapsedSeconds: 70.5, durationSeconds: 600)
    XCTAssertEqual(playhead.timeline.elapsedSeconds, 70.5)
  }

  func testControlsHideOnlyAfterTheLatestIdlePeriodWhilePlaying() {
    var visibility = PutioVideoControlsVisibility()
    let stale = visibility.idleGeneration
    visibility.interacted()

    visibility.idleElapsed(generation: stale, isPlaying: true)
    XCTAssertTrue(visibility.isVisible, "an earlier idle timer hid the controls")

    visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: false)
    XCTAssertTrue(visibility.isVisible, "paused controls hid")

    visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: true)
    XCTAssertFalse(visibility.isVisible)

    visibility.toggled()
    XCTAssertTrue(visibility.isVisible, "a tap did not bring the controls back")
  }

  func testPinnedControlsStay() {
    var visibility = PutioVideoControlsVisibility()
    visibility.set(.voiceOver, true)
    visibility.set(.scrubbing, true)
    visibility.set(.scrubbing, false)

    visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: true)
    visibility.toggled()
    XCTAssertTrue(visibility.isVisible, "controls hid while VoiceOver runs")

    visibility.set(.voiceOver, false)
    visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: true)
    XCTAssertFalse(visibility.isVisible)
  }
}
