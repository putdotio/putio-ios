import XCTest

@testable import PutioCore

@MainActor
private final class ManualWaitClock {
  private(set) var requested: [Duration] = []
  private var pending: [CheckedContinuation<Void, Never>] = []

  func sleep(_ duration: Duration) async throws {
    requested.append(duration)
    await withCheckedContinuation { pending.append($0) }
  }

  func advance() async {
    await settle()
    guard !pending.isEmpty else { return XCTFail("no timer is waiting") }
    pending.removeFirst().resume()
    await settle()
  }

  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }
}

@MainActor
final class PutioVideoWaitModelTests: XCTestCase {
  private func makeModel() -> (PutioVideoWaitModel, ManualWaitClock) {
    let clock = ManualWaitClock()
    return (PutioVideoWaitModel(sleep: { try await clock.sleep($0) }), clock)
  }

  func testPreparingLastsUntilThePlayerFirstPlays() {
    let (model, _) = makeModel()
    model.activityChanged(.waiting)
    model.activityChanged(.paused)
    XCTAssertEqual(model.state, .preparing)
    model.activityChanged(.playing)
    XCTAssertEqual(model.state, .clear)
  }

  func testBufferingShowsItsLabelAfterTenSecondsAndStallsAfterThirty() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    XCTAssertEqual(model.state, .buffering)
    await clock.advance()
    XCTAssertEqual(model.state, .bufferingLong)
    await clock.advance()
    XCTAssertEqual(model.state, .stalled)
    XCTAssertEqual(clock.requested, [.seconds(10), .seconds(20)])
  }

  func testRecoveryClearsTheWaitAndItsPendingTimer() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    await clock.advance()
    XCTAssertEqual(model.state, .bufferingLong)
    model.activityChanged(.playing)
    XCTAssertEqual(model.state, .clear)
    await clock.advance()
    XCTAssertEqual(model.state, .clear)
  }

  func testANewBufferRestartsTheCountFromZero() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    await clock.advance()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    XCTAssertEqual(model.state, .buffering)
    await clock.advance()
    await clock.advance()
    XCTAssertEqual(model.state, .bufferingLong)
  }

  func testStalledHoldsUntilPlaybackRecoversOnItsOwn() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    await clock.advance()
    await clock.advance()
    model.activityChanged(.waiting)
    model.activityChanged(.paused)
    XCTAssertEqual(model.state, .stalled)
    model.activityChanged(.playing)
    XCTAssertEqual(model.state, .clear)
  }

  func testPausingWhileBufferingClearsTheSpinner() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    model.activityChanged(.paused)
    XCTAssertEqual(model.state, .clear)
    await clock.advance()
    XCTAssertEqual(model.state, .clear)
  }

  func testRestartReturnsToPreparing() async {
    let (model, clock) = makeModel()
    model.activityChanged(.playing)
    model.activityChanged(.waiting)
    await clock.advance()
    await clock.advance()
    model.restart()
    XCTAssertEqual(model.state, .preparing)
    model.activityChanged(.playing)
    XCTAssertEqual(model.state, .clear)
  }
}
