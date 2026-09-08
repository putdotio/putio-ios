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
  let frames = (0..<40).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index),
      duration: 1,
      fingerprint: index < 3 ? root : index < 35 ? nested : back
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

@Test func journeyRecordingWindowSupportsMatchingInitialAndFinalSignInScreens() throws {
  let signIn = JourneyFrameFingerprint(samples: [10])
  let playback = JourneyFrameFingerprint(samples: [100])
  let unrelated = JourneyFrameFingerprint(samples: [250])
  let frames = (0..<60).map { index in
    let fingerprint =
      if index < 10 || index >= 50 {
        signIn
      } else if index >= 25 && index < 35 {
        playback
      } else {
        unrelated
      }
    return JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: fingerprint
    )
  }

  let window = try journeyRecordingWindow(
    frames: frames,
    root: signIn,
    nested: playback,
    back: signIn
  )

  #expect(abs(window.start) < 0.000_001)
  #expect(abs(window.duration - 5.3) < 0.000_001)
  #expect(window.frameCount == 53)
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

/// Root and nested screens as regular 0.1 s samples ending at 3.0 s; each
/// test appends its own returned-root tail.
private func journeyHeldFrameFixture() -> (
  root: JourneyFrameFingerprint,
  nested: JourneyFrameFingerprint,
  back: JourneyFrameFingerprint,
  frames: [JourneyVideoFrame]
) {
  let root = JourneyFrameFingerprint(samples: [10])
  let nested = JourneyFrameFingerprint(samples: [100])
  let back = JourneyFrameFingerprint(samples: [200])
  let frames = (0..<30).map { index in
    JourneyVideoFrame(
      presentationTime: Double(index) / 10,
      duration: 0.1,
      fingerprint: index < 15 ? root : nested
    )
  }
  return (root, nested, back, frames)
}

@Test func journeyRecordingWindowAcceptsAHeldStaticReturnedRootFrame() throws {
  // A fully static screen is a single held sample in a variable-frame-rate
  // recording; it must count as settled without further samples.
  var (root, nested, back, frames) = journeyHeldFrameFixture()
  // The decoder reports a bogus short duration; the next sample's timestamp
  // is what proves the frame was held.
  frames.append(JourneyVideoFrame(presentationTime: 3.0, duration: 0.003, fingerprint: back))
  frames.append(
    JourneyVideoFrame(
      presentationTime: 4.4, duration: 0.1, fingerprint: JourneyFrameFingerprint(samples: [250])))

  let window = try journeyRecordingWindow(frames: frames, root: root, nested: nested, back: back)

  #expect(abs(window.start - 0.5) < 0.000_001)
  // The trimmed proof keeps the whole held interval (3.0 to 4.4).
  #expect(abs(window.duration - 3.9) < 0.000_001)
}

@Test func journeyRecordingWindowDoesNotTrustALoneTerminalFrameDuration() {
  var (root, nested, back, frames) = journeyHeldFrameFixture()
  // A single final sample claiming a long duration has no timestamp behind it.
  frames.append(JourneyVideoFrame(presentationTime: 3.0, duration: 2.0, fingerprint: back))

  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(frames: frames, root: root, nested: nested, back: back)
  }
}

@Test func journeyRecordingWindowStillRejectsAFlickeringReturnedRoot() {
  var (root, nested, back, frames) = journeyHeldFrameFixture()
  // Two short back samples separated by an unrelated frame never settle.
  frames.append(JourneyVideoFrame(presentationTime: 3.0, duration: 0.05, fingerprint: back))
  frames.append(
    JourneyVideoFrame(
      presentationTime: 3.05, duration: 0.05, fingerprint: JourneyFrameFingerprint(samples: [250])))
  frames.append(JourneyVideoFrame(presentationTime: 3.1, duration: 0.05, fingerprint: back))

  #expect(throws: HarnessFailure.self) {
    try journeyRecordingWindow(frames: frames, root: root, nested: nested, back: back)
  }
}

@Test func journeyRecordingWindowEndsAtTheSuccessorTimestampNotABogusLongDuration() throws {
  var (root, nested, back, frames) = journeyHeldFrameFixture()
  // Held 0.4 s by timestamp, but the decoder claims 30 s.
  frames.append(JourneyVideoFrame(presentationTime: 3.0, duration: 30, fingerprint: back))
  frames.append(
    JourneyVideoFrame(
      presentationTime: 3.4, duration: 0.1, fingerprint: JourneyFrameFingerprint(samples: [250])))

  let window = try journeyRecordingWindow(frames: frames, root: root, nested: nested, back: back)

  #expect(abs(window.start - 0.5) < 0.000_001)
  #expect(abs(window.duration - 2.9) < 0.000_001)
}
