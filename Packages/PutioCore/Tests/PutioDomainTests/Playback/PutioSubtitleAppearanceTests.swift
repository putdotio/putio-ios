import Foundation
import XCTest

@testable import PutioDomain

final class PutioSubtitleAppearanceTests: XCTestCase {
  func testTimingStepsATenthOfASecondUpToTenSecondsEitherWayAndResets() {
    var timing = PutioSubtitleTiming()
    XCTAssertEqual(timing.text, "0.0 s")
    for _ in 0..<5 { timing.moveLater() }
    XCTAssertEqual(timing.seconds, 0.5, accuracy: 1e-9)
    XCTAssertEqual(timing.text, "+0.5 s")
    for _ in 0..<12 { timing.moveEarlier() }
    XCTAssertEqual(timing.text, "\u{2212}0.7 s")
    timing.reset()
    XCTAssertEqual(timing.text, "0.0 s")

    for _ in 0..<150 { timing.moveLater() }
    XCTAssertEqual(timing.text, "+10.0 s")
    for _ in 0..<250 { timing.moveEarlier() }
    XCTAssertEqual(timing.text, "\u{2212}10.0 s")
  }

  func testAChangeShowsOffsetSecondsAfterItsTime() {
    var changes = PutioSubtitleChanges<String>()
    changes.record(["First line"], at: 0)
    changes.record(["Second line"], at: 4)
    changes.record([], at: 8)

    XCTAssertEqual(changes.cues(at: 4.4, offset: 0.5), ["First line"])
    XCTAssertEqual(changes.cues(at: 4.5, offset: 0.5), ["Second line"])
    XCTAssertEqual(changes.cues(at: 3.5, offset: -0.5), ["Second line"])
    XCTAssertEqual(changes.cues(at: 8.4, offset: 0.5), ["Second line"])
    XCTAssertEqual(changes.cues(at: 8.5, offset: 0.5), [])
    XCTAssertEqual(changes.cues(at: 0.4, offset: 0.5), [])
  }

  func testAChangeReportedBeforeLaterOnesReplacesThemAfterASeekBack() {
    var changes = PutioSubtitleChanges<String>()
    changes.record(["Second line"], at: 4)
    changes.record(["Third line"], at: 8)
    changes.record(["First line"], at: 0)

    XCTAssertEqual(changes.cues(at: 9, offset: 0), ["First line"])
  }

  func testForgettingKeepsTheChangeStillShowing() {
    var changes = PutioSubtitleChanges<String>()
    changes.record(["First line"], at: 0)
    changes.record(["Second line"], at: 4)
    changes.record(["Third line"], at: 8)
    changes.forget(before: 5)

    XCTAssertEqual(changes.cues(at: 5, offset: 0), ["Second line"])
    XCTAssertEqual(changes.cues(at: 3, offset: 0), [])
  }

  @MainActor
  func testSizeIsRememberedAndStartsMedium() async throws {
    let suite = "PutioSubtitleAppearanceTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertEqual(PutioSubtitleSizeMemory(defaults: defaults).size, .medium)
    PutioSubtitleSizeMemory(defaults: defaults).size = .extraLarge
    XCTAssertEqual(PutioSubtitleSizeMemory(defaults: defaults).size, .extraLarge)
    defaults.set("huge", forKey: PutioSubtitleSizeMemory.key)
    XCTAssertEqual(PutioSubtitleSizeMemory(defaults: defaults).size, .medium)
  }
}
