import Foundation
import PutioCore

/// One row in the offline queue. Identity is the put.io file id, so a
/// conversion-then-download handoff or a retry keeps the same item.
struct PutioOfflineItem: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case video
    case audio
  }

  enum Stage: Codable, Equatable, Sendable {
    case queued
    case waitingToConvert
    case converting(progress: Double)
    case downloading(progress: Double)
    case waitingForNetwork(progress: Double)
    case waitingForStorage
    case paused(progress: Double)
    case completed
    case failed(PutioOfflineFailure)
    case missing
  }

  let id: PutioFileID
  let parentID: PutioFileID
  let name: String
  let kind: Kind
  let createdAt: Date
  var stage: Stage
  /// Relative path under the app's home; AVFoundation picks the final location.
  var localPath: String?
  var storedBytes: Int64
  /// Tracks actually present in the stored asset, disclosed in details.
  var storedAudioTracks: [PutioOfflineTrack]
  var storedSubtitleTracks: [PutioOfflineTrack]
  var resumePositionSeconds: Int
  /// A position saved while offline that the server has not received yet.
  var pendingPositionSeconds: Int?

  var progress: Double {
    switch stage {
    case .queued, .waitingToConvert, .waitingForStorage: 0
    case .converting(let progress), .downloading(let progress), .waitingForNetwork(let progress),
      .paused(let progress):
      progress
    case .completed: 1
    case .failed, .missing: 0
    }
  }

  var isActive: Bool {
    switch stage {
    case .waitingToConvert, .converting, .downloading, .waitingForNetwork: true
    default: false
    }
  }

  var isPlayable: Bool {
    guard stage == .completed, localPath != nil else { return false }
    return !isOriginal || PutioOfflineOriginalPackage.playsInAVPlayer(name: name)
  }

  var isOriginal: Bool { playbackMethod == .directPlay }

  /// The stored size, shown only once the download completes; a partial
  /// package's byte count is not a size the user can act on.
  var storedSizeText: String? {
    guard stage == .completed else { return nil }
    return PutioFileRowModel.sizeText(bytes: storedBytes)
  }

  var estimatedBytes: Int64
  var failedProgress: Double?
  var isWatched: Bool?
  var playbackMethod: PutioPlaybackMethod? = nil
  var completedAt: Date?

  var receivedBytes: Int64 {
    Int64((Double(estimatedBytes) * progress).rounded(.down))
  }

  var bytesOnDevice: Int64 {
    switch stage {
    case .completed: storedBytes
    case .downloading, .waitingForNetwork, .paused: receivedBytes
    case .queued, .waitingToConvert, .converting, .waitingForStorage, .failed, .missing: 0
    }
  }

  func downloadState(queuePosition: Int?) -> PutioDownloadState {
    if let queuePosition { return .queued(position: queuePosition) }
    return switch stage {
    case .queued: .queued(position: 1)
    case .waitingToConvert: .waitingToConvert
    case .converting(let progress): .converting(progress: progress)
    case .downloading: .downloading(receivedBytes: receivedBytes, totalBytes: estimatedBytes)
    case .waitingForNetwork:
      .waiting(.network, receivedBytes: receivedBytes, totalBytes: estimatedBytes)
    case .waitingForStorage:
      .waiting(.storage, receivedBytes: receivedBytes, totalBytes: estimatedBytes)
    case .paused: .paused(receivedBytes: receivedBytes, totalBytes: estimatedBytes)
    case .completed: .idle
    case .failed(let failure): .failed(reason: failure.reason, canRetry: failure.canRetry)
    case .missing: .missing
    }
  }
}

struct PutioOfflineSections: Equatable {
  enum Kind: CaseIterable {
    case downloading
    case attention
    case onDevice
  }

  struct Section: Equatable, Identifiable {
    let kind: Kind
    let items: [PutioOfflineItem]

    var id: Kind { kind }
  }

  let sections: [Section]
  let queuePositions: [PutioFileID: Int]

  init(
    _ items: [PutioOfflineItem], waitingForSlot: Set<PutioFileID> = [],
    removing: [PutioOfflineItem] = []
  ) {
    var downloading: [PutioOfflineItem] = []
    var attention: [PutioOfflineItem] = []
    var onDevice: [PutioOfflineItem] = []
    var positions: [PutioFileID: Int] = [:]
    for item in items {
      switch item.stage {
      case .queued:
        positions[item.id] = positions.count + 1
        downloading.append(item)
      case .paused where waitingForSlot.contains(item.id):
        positions[item.id] = positions.count + 1
        downloading.append(item)
      case .waitingToConvert, .converting, .downloading, .waitingForNetwork, .waitingForStorage,
        .paused:
        downloading.append(item)
      case .failed, .missing:
        attention.append(item)
      case .completed:
        onDevice.append(item)
      }
    }
    let listed = Set(items.map(\.id))
    for item in removing where !listed.contains(item.id) {
      switch item.stage {
      case .completed: onDevice.append(item)
      case .failed, .missing: attention.append(item)
      default: downloading.append(item)
      }
    }
    onDevice = onDevice.enumerated()
      .sorted { lhs, rhs in
        lhs.element.createdAt == rhs.element.createdAt
          ? lhs.offset < rhs.offset : lhs.element.createdAt > rhs.element.createdAt
      }
      .map(\.element)
    sections = [
      Section(kind: .downloading, items: downloading),
      Section(kind: .attention, items: attention),
      Section(kind: .onDevice, items: onDevice),
    ].filter { !$0.items.isEmpty }
    queuePositions = positions
  }
}

enum PutioOfflineBulkAction: Equatable {
  case pauseAll
  case resumeAll
}

struct PutioOfflineTrack: Codable, Equatable, Hashable, Sendable {
  let languageCode: String
  let displayName: String
}

struct PutioOfflineFailure: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case conversion
    case resolution
    case download
    case storage
    case notFound
    case authentication
    case unexpected
  }

  let kind: Kind
  let message: String

  var canRetry: Bool { kind != .notFound }

  var reason: String {
    switch kind {
    case .resolution: String(localized: "Connection lost")
    case .authentication: String(localized: "Sign in again")
    case .notFound: String(localized: "No longer available")
    case .storage: String(localized: "Not enough storage")
    case .download, .conversion, .unexpected: String(localized: "Couldn’t download")
    }
  }

  static let authentication = Self(
    kind: .authentication, message: String(localized: "Sign in again to continue this download."))

  static let download = Self(
    kind: .download, message: String(localized: "The download could not finish. Try again."))
  static let conversion = Self(
    kind: .conversion, message: String(localized: "The conversion did not finish. Try again."))
  static let storage = Self(
    kind: .storage,
    message: String(localized: "Not enough space on this device. Free up storage and try again."))
  static let notFound = Self(
    kind: .notFound, message: String(localized: "It may have been moved or deleted."))

  static func resolving(_ error: Error) -> Self? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: .authentication
    case .notFound: .notFound
    case .rateLimited:
      Self(
        kind: .unexpected,
        message: String(localized: "put.io is receiving too many requests. Try again shortly."))
    case .transient:
      Self(kind: .resolution, message: String(localized: "Check your connection and try again."))
    case .invalidResponse:
      Self(
        kind: .unexpected,
        message: String(localized: "put.io returned an invalid response. Try again."))
    case .unknown, nil:
      Self(
        kind: .unexpected,
        message: String(localized: "put.io could not prepare this file. Try again."))
    }
  }
}

struct PutioOfflineConversionError: Error {}

/// A queue write that did not reach disk. The signed-in shell shows it on
/// every tab until a retry writes everything or the user dismisses it.
enum PutioOfflinePersistenceFailure: Equatable, Sendable {
  /// The queue or its package record is behind on disk; writing again may fix it.
  case unsaved(outOfSpace: Bool)

  static func isOutOfSpace(_ error: Error) -> Bool {
    (error as NSError).code == NSFileWriteOutOfSpaceError
  }

  var title: String {
    switch self {
    case .unsaved: String(localized: "Could not save downloads")
    }
  }

  var message: String {
    switch self {
    case .unsaved(let outOfSpace):
      outOfSpace
        ? String(
          localized:
            "This device is out of space, so changes to your downloads were not saved. Free up storage and try again."
        )
        : String(
          localized: "Changes to your downloads could not be saved on this device. Try again.")
    }
  }
}
