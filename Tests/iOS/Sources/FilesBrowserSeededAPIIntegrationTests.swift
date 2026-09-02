import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FilesBrowserSeededAPIIntegrationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    HarnessSeededAPI.resetPlaybackPositions()
    HarnessSeededAPI.resetVideoConversion()
    HarnessSeededAPI.resetFileActions()
  }

  func testRootFolderAndNestedFileFlow() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()

    guard case .signedIn = runtime.session.state else {
      return XCTFail("expected seeded session to restore")
    }

    let folderID = PutioFileID(rawValue: 410)
    let fileID = PutioFileID(rawValue: 411)
    let root = try await runtime.listFiles(parentID: .root)
    let folder = try XCTUnwrap(root.items.first { $0.id == folderID })
    let folderRoute = try XCTUnwrap(
      PutioBrowserItemPresentation(item: folder).folderRoute
    )
    let nested = try await runtime.listFiles(parentID: folderRoute.id)
    let file = try XCTUnwrap(nested.items.first { $0.id == fileID })
    let fileRoute = try XCTUnwrap(
      PutioBrowserItemPresentation(item: file).fileRoute
    )

    XCTAssertEqual(root.folder?.id, .root)
    XCTAssertEqual(
      root.items.map(\.id),
      [folderID, PutioFileID(rawValue: 412), PutioFileID(rawValue: 413)]
    )
    XCTAssertEqual(folderRoute.id, folderID)
    XCTAssertEqual(nested.folder?.id, folderID)
    XCTAssertEqual(nested.items.map(\.id), [fileID])
    XCTAssertEqual(fileRoute.id, fileID)
    XCTAssertEqual(fileRoute.item.parentID, folderID)
    XCTAssertEqual(fileRoute.item.kind, .video)
  }

  func testSeededConversionTransitionsNestedVideoToPlayback() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()

    let root = try await runtime.listFiles(parentID: .root)
    let nested = try await runtime.listFiles(parentID: PutioFileID(rawValue: 410))
    let videos = (root.items + nested.items).filter { $0.kind == .video }

    let initialResolution = try await runtime.resolveVideoPlaybackSource(
      fileID: PutioFileID(rawValue: 411)
    )
    XCTAssertEqual(initialResolution, .conversionRequired)
    do {
      try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))
      XCTFail("expected the first seeded conversion request to fail")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .transient)
    }
    try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))
    let queued = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
    let converting = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
    let completed = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
    XCTAssertEqual(queued, .queued)
    guard case .converting(let progress) = converting else {
      return XCTFail("expected converting status, got \(converting)")
    }
    XCTAssertEqual(progress, 0.35, accuracy: 0.001)
    XCTAssertEqual(completed, .completed)

    var sources: [Int: PutioPlaybackSource] = [:]
    for video in videos {
      guard case .ready(let source) = try await runtime.resolveVideoPlaybackSource(fileID: video.id)
      else { return XCTFail("expected seeded video \(video.id.rawValue) to be ready") }
      sources[video.id.rawValue] = source
    }

    XCTAssertEqual(Set(sources.keys), [411, 412])
    XCTAssertEqual(sources[411]?.url.path, "/v2/files/411/hls/media.m3u8")
    XCTAssertEqual(sources[411]?.startFromSeconds, 90)
    XCTAssertEqual(sources[412]?.url.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertEqual(sources[412]?.startFromSeconds, 589)
  }

  func testSeededPlaybackPositionRoundTripsThroughPlaybackAndFolderFixtures() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()
    for rawFileID in [411, 412] {
      let fileID = PutioFileID(rawValue: rawFileID)
      if rawFileID == 411 {
        try await completeSeededConversion(runtime: runtime, fileID: fileID)
      }
      try await runtime.reportVideoPlaybackPosition(fileID: fileID, seconds: 137)
      let resolution = try await runtime.resolveVideoPlaybackSource(fileID: fileID)

      guard case .ready(let source) = resolution else {
        return XCTFail("expected seeded video \(rawFileID) to remain ready after reporting")
      }
      XCTAssertEqual(source.startFromSeconds, 137)

      let parentID = PutioFileID(rawValue: rawFileID == 411 ? 410 : 0)
      let refreshed = try await runtime.listFiles(parentID: parentID)
      let refreshedFile = try XCTUnwrap(refreshed.items.first { $0.id == fileID })
      XCTAssertEqual(refreshedFile.resumePositionSeconds, 137)
      XCTAssertTrue(refreshedFile.isWatched)

      try await runtime.reportVideoPlaybackPosition(fileID: fileID, seconds: 0)
      let reset = try await runtime.listFiles(parentID: parentID)
      let resetFile = try XCTUnwrap(reset.items.first { $0.id == fileID })
      XCTAssertEqual(resetFile.resumePositionSeconds, 0)
      XCTAssertFalse(resetFile.isWatched)
    }
  }

  func testSeededNextVideoPreservesSuccessorIdentityAndResumePosition() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()

    let loadedNextVideo = try await runtime.findNextVideo(after: PutioFileID(rawValue: 412))
    let nextVideo = try XCTUnwrap(loadedNextVideo)
    XCTAssertEqual(nextVideo.id, PutioFileID(rawValue: 414))
    XCTAssertEqual(nextVideo.parentID, .root)
    XCTAssertEqual(nextVideo.name, "Root Movie 2.mkv")

    guard
      case .ready(let source) = try await runtime.resolveVideoPlaybackSource(
        fileID: nextVideo.id
      )
    else {
      return XCTFail("expected the seeded successor to resolve")
    }
    XCTAssertEqual(source.startFromSeconds, 37)
    let finalSuccessor = try await runtime.findNextVideo(after: nextVideo.id)
    XCTAssertNil(finalSuccessor)
  }

  func testSeededFileActionsCreateRenameRetryAndDelete() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()

    let created = try await runtime.createFolder(name: "Watch Later", parentID: .root)
    XCTAssertEqual(created.id, PutioFileID(rawValue: 415))
    XCTAssertEqual(created.name, "Watch Later")
    XCTAssertEqual(created.kind, .folder)
    var root = try await runtime.listFiles(parentID: .root)
    XCTAssertEqual(root.items.first { $0.id == created.id }?.name, "Watch Later")

    do {
      try await runtime.renameFile(fileID: created.id, name: "Weekend")
      XCTFail("expected the first seeded rename to fail")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .transient)
    }
    root = try await runtime.listFiles(parentID: .root)
    XCTAssertEqual(root.items.first { $0.id == created.id }?.name, "Watch Later")

    try await runtime.renameFile(fileID: created.id, name: "Weekend")
    root = try await runtime.listFiles(parentID: .root)
    XCTAssertEqual(root.items.first { $0.id == created.id }?.name, "Weekend")

    try await runtime.deleteFile(fileID: created.id)
    root = try await runtime.listFiles(parentID: .root)
    XCTAssertFalse(root.items.contains { $0.id == created.id })
  }

  func testCancellingSeededRenameDoesNotWaitForDelayedFixture() async throws {
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()
    let created = try await runtime.createFolder(name: "Watch Later", parentID: .root)
    let clock = ContinuousClock()
    let startedAt = clock.now
    let rename = Task {
      try await runtime.renameFile(fileID: created.id, name: "Weekend")
    }

    try await Task.sleep(for: .milliseconds(100))
    rename.cancel()

    do {
      try await rename.value
      XCTFail("expected the delayed rename to be cancelled")
    } catch {
      XCTAssertTrue(error is CancellationError, "unexpected cancellation error: \(error)")
    }
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(2))
  }

  func testCancelledHarnessDeliverySuppressesItsCallbacks() {
    let gate = HarnessResponseDeliveryGate()
    let generation = gate.begin()
    var callbackCount = 0

    gate.cancel()
    gate.deliver(generation: generation) {
      callbackCount += 1
    }

    XCTAssertEqual(callbackCount, 0)
  }

  private func completeSeededConversion(runtime: PutioRuntime, fileID: PutioFileID) async throws {
    do {
      try await runtime.startVideoConversion(fileID: fileID)
      XCTFail("expected the first seeded conversion request to fail")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .transient)
    }
    try await runtime.startVideoConversion(fileID: fileID)
    _ = try await runtime.videoConversionStatus(fileID: fileID)
    _ = try await runtime.videoConversionStatus(fileID: fileID)
    let completed = try await runtime.videoConversionStatus(fileID: fileID)
    XCTAssertEqual(completed, .completed)
  }

  func testHarnessSignInPersistsForRestoreAndSignOutClearsTheSession() async throws {
    let tokenStore = PutioKeychainTokenStore()
    try tokenStore.clear()
    defer { try? tokenStore.clear() }

    let signingInRuntime = PutioRuntimeFactory.make(scenario: .filesBrowser)
    await signingInRuntime.session.restore()
    XCTAssertEqual(signingInRuntime.session.state, .signedOut(nil))

    let request = try signingInRuntime.session.beginSignIn()
    let callback = try PutioRuntimeFactory.runtimeProofCallback(for: request)
    await signingInRuntime.session.completeSignIn(callbackURL: callback)
    guard case .signedIn = signingInRuntime.session.state else {
      return XCTFail("deterministic callback did not sign in")
    }

    let restoredRuntime = PutioRuntimeFactory.make(scenario: .filesBrowser)
    await restoredRuntime.session.restore()
    guard case .signedIn = restoredRuntime.session.state else {
      return XCTFail("persisted harness session did not restore")
    }

    await restoredRuntime.session.signOut()
    XCTAssertEqual(restoredRuntime.session.state, .signedOut(.userSignedOut))

    let signedOutRuntime = PutioRuntimeFactory.make(scenario: .filesBrowser)
    await signedOutRuntime.session.restore()
    XCTAssertEqual(signedOutRuntime.session.state, .signedOut(nil))
  }
}
