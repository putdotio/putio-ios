import Foundation

public typealias PutioNextVideoResetWait =
  @MainActor @Sendable (PutioFileID) async -> Void
public typealias PutioNextVideoSleep =
  @MainActor @Sendable (Duration) async throws -> Void
public typealias PutioNextVideoAutoplayPolicy = @MainActor @Sendable () async -> Bool

public struct PutioPlayableNextVideo: Equatable, Sendable {
  public let video: PutioNextVideo
  public let initialResolution: PutioPlaybackResolution
}

/// A downloaded successor plays from its local file, so it keeps working
/// offline and its locally recorded position wins over the server's.
@MainActor
public func resolveSuccessorSource(
  fileID: PutioFileID,
  localSource: @MainActor (PutioFileID) -> PutioPlaybackSource?,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlaybackResolution {
  if let local = localSource(fileID) { return .ready(local) }
  return try await resolve(fileID)
}

/// The server owns the successor order. When it cannot answer, a downloaded
/// successor from the offline queue keeps a finished download advancing
/// offline; a server answer of "none" is final and never consults the queue.
@MainActor
public func prepareNextVideo(
  after fileID: PutioFileID,
  findNext: @MainActor @Sendable (PutioFileID) async throws -> PutioNextVideo?,
  findOfflineNext: @MainActor (PutioFileID) -> PutioNextVideo? = { _ in nil },
  waitForPendingReports: PutioNextVideoResetWait,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlayableNextVideo? {
  guard
    let video = try await findNextVideo(
      after: fileID, findNext: findNext, findOfflineNext: findOfflineNext)
  else { return nil }
  return try await preparePlayableVideo(
    video, waitForPendingReports: waitForPendingReports, resolve: resolve)
}

@MainActor
public func findNextVideo(
  after fileID: PutioFileID,
  findNext: @MainActor @Sendable (PutioFileID) async throws -> PutioNextVideo?,
  findOfflineNext: @MainActor (PutioFileID) -> PutioNextVideo? = { _ in nil }
) async throws -> PutioNextVideo? {
  do {
    return try await findNext(fileID)
  } catch {
    guard !(error is CancellationError), let offline = findOfflineNext(fileID) else { throw error }
    return offline
  }
}

@MainActor
public func preparePlayableVideo(
  _ video: PutioNextVideo,
  waitForPendingReports: PutioNextVideoResetWait,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlayableNextVideo {
  await waitForPendingReports(video.id)
  try Task.checkCancellation()
  let resolution = try await resolve(video.id)
  return PutioPlayableNextVideo(video: video, initialResolution: resolution)
}
