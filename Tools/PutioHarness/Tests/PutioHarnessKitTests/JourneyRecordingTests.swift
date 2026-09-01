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

@Test func journeyRecordingWindowCapsLoadedRootContextAtOneSecond() throws {
  let root = JourneyFrameFingerprint(samples: [10])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  let frames = (0..<130).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: index < 100 ? root : index < 115 ? nested : back
    )
  }

  let window = try journeyRecordingWindow(
    frames: frames,
    root: root,
    nested: nested,
    back: back
  )

  #expect(abs(window.start - 9.0) < 0.000_001)
  #expect(window.duration < 4)
}

@Test func journeyRecordingWindowCapsSparseHeldRootContextAtOneSecond() throws {
  let root = JourneyFrameFingerprint(samples: [10])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  var frames = [
    JourneyVideoFrame(
      presentationTime: 0,
      duration: 20,
      fingerprint: root
    )
  ]
  frames += (0..<15).map { index in
    JourneyVideoFrame(
      presentationTime: 20 + Double(index) / 10,
      duration: 0.1,
      fingerprint: nested
    )
  }
  frames += (0..<15).map { index in
    JourneyVideoFrame(
      presentationTime: 21.5 + Double(index) / 10,
      duration: 0.1,
      fingerprint: back
    )
  }

  let window = try journeyRecordingWindow(
    frames: frames,
    root: root,
    nested: nested,
    back: back
  )

  #expect(abs(window.start - 19) < 0.000_001)
  #expect(window.duration < 5)
}

@Test func journeyRecordingWindowUsesFinalRootRunBeforeNested() throws {
  let root = JourneyFrameFingerprint(samples: [10])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  let unrelated = JourneyFrameFingerprint(samples: [250])
  let frames = (0..<90).map { index in
    let fingerprint =
      if index < 5 || (index >= 50 && index < 60) {
        root
      } else if index < 50 {
        unrelated
      } else if index < 75 {
        nested
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

  #expect(abs(window.start - 5) < 0.000_001)
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

@Test func journeyCaptureCompletionStopsWhenTestExits() {
  var slept = false
  let completed = waitForJourneyCaptureComplete(
    markerExists: { false },
    processIsRunning: { false },
    sleep: { _ in slept = true }
  )

  #expect(!completed)
  #expect(!slept)
}

@Test func journeyCaptureCompletionReturnsWhenMarkerAppears() {
  let completed = waitForJourneyCaptureComplete(
    markerExists: { true },
    processIsRunning: { false },
    sleep: { _ in Issue.record("unexpected sleep") }
  )

  #expect(completed)
}

@Test func journeyCaptureCompletionStopsAtTimeout() {
  var sleepCount = 0
  let completed = waitForJourneyCaptureComplete(
    markerExists: { false },
    processIsRunning: { true },
    now: { Date(timeIntervalSince1970: 0) },
    sleep: { _ in sleepCount += 1 },
    timeout: 0
  )

  #expect(!completed)
  #expect(sleepCount == 1)
}

@Test func missingJourneyCaptureCompletionPreservesTestDiagnostics() {
  do {
    try requireJourneyCaptureCompletion(
      false,
      testOutput: ProcessOutput(status: 0, stdout: "journey stdout", stderr: "journey stderr")
    )
    Issue.record("expected missing capture completion to fail")
  } catch let error as HarnessFailure {
    #expect(error.message.contains("did not signal capture completion"))
    #expect(error.message.contains("journey stdout"))
    #expect(error.message.contains("journey stderr"))
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test func journeyRecordingTrimPropagatesSourceDecodeFailureBeforeConversion() {
  var converted = false

  #expect(throws: HarnessFailure.self) {
    try performJourneyRecordingTrim(
      source: URL(fileURLWithPath: "/source.mp4"),
      output: URL(fileURLWithPath: "/output.mp4"),
      root: JourneyFrameFingerprint(samples: [0]),
      nested: JourneyFrameFingerprint(samples: [100]),
      back: JourneyFrameFingerprint(samples: [200]),
      readFrames: { _ in throw HarnessFailure("decode failed") },
      convert: { _, _, _ in converted = true },
      readDuration: { _ in 3 }
    )
  }
  #expect(!converted)
}

@Test func journeyRecordingTrimPropagatesConversionFailure() {
  let fixture = journeyTrimFixture()
  var readCount = 0

  #expect(throws: HarnessFailure.self) {
    try performJourneyRecordingTrim(
      source: URL(fileURLWithPath: "/source.mp4"),
      output: URL(fileURLWithPath: "/output.mp4"),
      root: fixture.root,
      nested: fixture.nested,
      back: fixture.back,
      readFrames: { _ in
        readCount += 1
        return fixture.frames
      },
      convert: { _, _, _ in throw HarnessFailure("avconvert failed") },
      readDuration: { _ in 3 }
    )
  }
  #expect(readCount == 1)
}

@Test func journeyRecordingTrimRejectsInvalidConvertedOutput() {
  let fixture = journeyTrimFixture()

  #expect(throws: HarnessFailure.self) {
    try performJourneyRecordingTrim(
      source: URL(fileURLWithPath: "/source.mp4"),
      output: URL(fileURLWithPath: "/output.mp4"),
      root: fixture.root,
      nested: fixture.nested,
      back: fixture.back,
      readFrames: { _ in fixture.frames },
      convert: { _, _, _ in },
      readDuration: { _ in .infinity }
    )
  }
}

private func journeyTrimFixture() -> (
  root: JourneyFrameFingerprint,
  nested: JourneyFrameFingerprint,
  back: JourneyFrameFingerprint,
  frames: [JourneyVideoFrame]
) {
  let root = JourneyFrameFingerprint(samples: [0])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  let frames = (0..<30).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: index < 10 ? root : index < 20 ? nested : back
    )
  }
  return (root, nested, back, frames)
}
