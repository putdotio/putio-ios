import Foundation
import Testing

@testable import PutioHarnessKit

@Test func journeyRecordingWindowIncludesOneSecondOfLoadedRootContext() throws {
  let window = try journeyRecordingWindow(
    sourceDuration: 54.1,
    captureStartOffset: 40.9,
    captureDuration: 10.2
  )

  #expect(abs(window.start - 39.9) < 0.000_001)
  #expect(abs(window.duration - 11.2) < 0.000_001)
}

@Test func journeyRecordingWindowRejectsProofLongerThanCeiling() throws {
  #expect(
    try journeyRecordingWindow(
      sourceDuration: 54.1,
      captureStartOffset: 0,
      captureDuration: maximumJourneyRecordingDuration
    ).duration == maximumJourneyRecordingDuration
  )
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      sourceDuration: 54.1,
      captureStartOffset: 0,
      captureDuration: maximumJourneyRecordingDuration + 0.1
    )
  }
}

@Test func journeyRecordingWindowRejectsInvalidDurations() {
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      sourceDuration: .infinity,
      captureStartOffset: 3,
      captureDuration: 10
    )
  }
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      sourceDuration: 5,
      captureStartOffset: 3,
      captureDuration: 10
    )
  }
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      sourceDuration: 20,
      captureStartOffset: -1,
      captureDuration: 10
    )
  }
}
