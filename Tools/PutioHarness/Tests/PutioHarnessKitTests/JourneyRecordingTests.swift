import Foundation
import Testing

@testable import PutioHarnessKit

@Test func journeyRecordingWindowUsesScreenshotMatchedFrameBoundaries() throws {
  let root = JourneyFrameFingerprint(samples: [10, 10, 10])
  let nested = JourneyFrameFingerprint(samples: [100, 100, 100])
  let back = JourneyFrameFingerprint(samples: [12, 12, 12])
  let frames = (0..<30).map { index in
    let fingerprint =
      if index < 5 { JourneyFrameFingerprint(samples: [250, 250, 250]) } else if index < 10 {
        root
      } else if index < 20 {
        nested
      } else if index == 20 {
        JourneyFrameFingerprint(samples: [14, 14, 14])
      } else if index == 21 {
        JourneyFrameFingerprint(samples: [250, 250, 250])
      } else {
        back
      }
    return JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: fingerprint
    )
  }

  let window = try journeyRecordingWindow(
    frames: frames,
    root: root,
    nested: nested,
    back: back
  )

  #expect(abs(window.start - 0.5) < 0.000_001)
  #expect(abs(window.duration - 2.0) < 0.000_001)
  #expect(window.frameCount == 20)
}

@Test func journeyRecordingWindowRejectsProofLongerThanCeiling() {
  let root = JourneyFrameFingerprint(samples: [0])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  let frames = (0..<30).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index),
      duration: 1,
      fingerprint: index == 0 ? root : index == 1 ? nested : back
    )
  }

  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      frames: frames,
      root: root,
      nested: nested,
      back: back
    )
  }
}

@Test func journeyRecordingWindowRejectsMissingOrShortSequences() {
  let root = JourneyFrameFingerprint(samples: [0])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      frames: [],
      root: root,
      nested: nested,
      back: back
    )
  }

  let frames = (0..<20).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: index < 10 ? root : back
    )
  }
  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(
      frames: frames,
      root: root,
      nested: nested,
      back: back
    )
  }
}

@Test func journeyFrameDifferenceRejectsSparseHighContrastChanges() {
  let reference = JourneyFrameFingerprint(samples: [0, 0, 0, 0, 0, 0])
  let sparseChange = JourneyFrameFingerprint(samples: [0, 0, 0, 0, 0, 48])

  #expect(journeyFrameDifference(reference, sparseChange) > maximumJourneyFrameDifference)
}
