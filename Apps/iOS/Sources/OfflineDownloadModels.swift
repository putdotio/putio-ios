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
    case converting(progress: Double)
    case downloading(progress: Double)
    case paused(progress: Double)
    case completed
    case failed(PutioOfflineFailure)
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
  /// Audio tracks the user asked for, by language code, in selection order.
  var selectedAudioLanguages: [String]
  /// Tracks actually present in the stored asset, disclosed in details.
  var storedAudioTracks: [PutioOfflineTrack]
  var storedSubtitleTracks: [PutioOfflineTrack]
  var resumePositionSeconds: Int
  /// A position saved while offline that the server has not received yet.
  var pendingPositionSeconds: Int?

  var progress: Double {
    switch stage {
    case .queued: 0
    case .converting(let progress), .downloading(let progress), .paused(let progress): progress
    case .completed: 1
    case .failed: 0
    }
  }

  var isActive: Bool {
    switch stage {
    case .converting, .downloading: true
    default: false
    }
  }

  var isPlayable: Bool {
    stage == .completed && localPath != nil
  }

  /// The stored size, shown only once the download completes; a partial
  /// package's byte count is not a size the user can act on.
  var storedSizeText: String? {
    guard stage == .completed else { return nil }
    return PutioFileRowModel.sizeText(bytes: storedBytes)
  }

  /// The picker's estimate at enqueue time, enforced again before start.
  var estimatedBytes: Int64
  /// Set when the item was queued before its asset could be inspected; the
  /// queue selects every language once conversion finishes.
  var awaitsLanguageSelection: Bool = false
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
  }

  let kind: Kind
  let message: String

  var canRetry: Bool { kind != .notFound }

  static let authentication = Self(
    kind: .authentication, message: "Sign in again to continue this download.")

  static let download = Self(kind: .download, message: "The download could not finish. Try again.")
  static let conversion = Self(
    kind: .conversion, message: "The conversion did not finish. Try again.")
  static let storage = Self(
    kind: .storage, message: "Not enough space on this device. Free up storage and try again.")
  static let notFound = Self(kind: .notFound, message: "It may have been moved or deleted.")

  static func resolving(_ error: Error) -> Self? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: .authentication
    case .notFound: .notFound
    case .rateLimited:
      Self(kind: .resolution, message: "put.io is receiving too many requests. Try again shortly.")
    case .transient: Self(kind: .resolution, message: "Check your connection and try again.")
    case .invalidResponse:
      Self(kind: .resolution, message: "put.io returned an invalid response. Try again.")
    case .unknown, nil:
      Self(kind: .resolution, message: "put.io could not prepare this file. Try again.")
    }
  }
}

/// An audio language the asset offers, with the bytes it adds to the download.
struct PutioOfflineAudioOption: Identifiable, Equatable, Sendable {
  let languageCode: String
  let displayName: String
  let estimatedBytes: Int64

  var id: String { languageCode }
}

struct PutioOfflineInventory: Equatable, Sendable {
  let videoBytes: Int64
  let audioOptions: [PutioOfflineAudioOption]
  let subtitleTracks: [PutioOfflineTrack]

  /// The bytes the download will take with the given languages selected.
  func estimatedBytes(selecting languages: [String]) -> Int64 {
    videoBytes
      + audioOptions.filter { languages.contains($0.languageCode) }.map(\.estimatedBytes).reduce(
        0, +)
  }
}

struct PutioOfflineConversionError: Error {}

/// A queue write that did not reach disk. The signed-in shell shows it on
/// every tab until a retry writes everything or the user dismisses it.
enum PutioOfflinePersistenceFailure: Equatable, Sendable {
  /// The queue or its package record is behind on disk; writing again may fix it.
  case unsaved(outOfSpace: Bool)
  /// A removal that also takes originals stopped before touching anything,
  /// because the record of owed originals could not be written.
  case removalNotStarted(outOfSpace: Bool, count: Int)

  static func isOutOfSpace(_ error: Error) -> Bool {
    (error as NSError).code == NSFileWriteOutOfSpaceError
  }

  var canRetry: Bool {
    if case .unsaved = self { return true }
    return false
  }

  var title: String {
    switch self {
    case .unsaved: "Could not save downloads"
    case .removalNotStarted(_, 1): "Could not remove download"
    case .removalNotStarted: "Could not remove downloads"
    }
  }

  var message: String {
    switch self {
    case .unsaved(let outOfSpace):
      outOfSpace
        ? "This device is out of space, so changes to your downloads were not saved. Free up storage and try again."
        : "Changes to your downloads could not be saved on this device. Try again."
    case .removalNotStarted(true, 1):
      "Nothing was removed because this device is out of space. Free up storage and remove the download again."
    case .removalNotStarted(true, _):
      "Nothing was removed because this device is out of space. Free up storage and remove the downloads again."
    case .removalNotStarted(false, 1):
      "Nothing was removed because this device could not save the change. Remove the download again."
    case .removalNotStarted(false, _):
      "Nothing was removed because this device could not save the change. Remove the downloads again."
    }
  }
}
