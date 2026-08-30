import Foundation
import Testing

@testable import PutioHarnessKit

@Test func journeyRecordingWindowKeepsOnlyBoundedLeadingContext() throws {
  let window = try journeyRecordingWindow(sourceDuration: 54.1, captureDuration: 10.2)

  #expect(abs(window.start - 40.9) < 0.000_001)
  #expect(abs(window.duration - 13.2) < 0.000_001)
}

@Test func journeyRecordingWindowRejectsProofLongerThanCeiling() throws {
  #expect(
    try journeyRecordingWindow(sourceDuration: 54.1, captureDuration: 22).duration
      == maximumJourneyRecordingDuration
  )
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(sourceDuration: 54.1, captureDuration: 23)
  }
}

@Test func journeyRecordingWindowRejectsInvalidDurations() {
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(sourceDuration: .infinity, captureDuration: 10)
  }
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(sourceDuration: 5, captureDuration: 10)
  }
}
