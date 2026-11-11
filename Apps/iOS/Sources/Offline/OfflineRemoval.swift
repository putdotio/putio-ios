import Foundation
import PutioCore

// MARK: - Outcome

/// A download the user asked to remove, kept by name because the queue row is
/// gone by the time a remote failure is reported. `movesToTrash` is what the
/// confirmation promised.
struct PutioOfflineRemovalTarget: Identifiable, Equatable, Codable, Sendable {
  let id: PutioFileID
  let name: String
  let movesToTrash: Bool
}

/// Why the original was not taken. Server-side reasons are offered a retry;
/// a changed Trash setting is not, since only a new confirmation could
/// authorize the other outcome.
struct PutioOfflineOriginalFailure: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case transient
    case rateLimited
    case unknown
    /// The account's Trash setting could not be confirmed, so nothing was sent.
    case settingUnconfirmed
    case trashSettingChanged

    var canRetry: Bool { self != .trashSettingChanged }

    init(_ error: Error) {
      switch error as? PutioRuntimeError {
      case .transient, .authenticationRequired, .sessionExpired: self = .transient
      case .rateLimited: self = .rateLimited
      case .invalidResponse, .unknown, .notFound, nil: self = .unknown
      }
    }
  }

  let target: PutioOfflineRemovalTarget
  let reason: Reason
}

/// The result of asking put.io for the originals. The local copies are already
/// gone whatever this says; it only describes the remote side.
struct PutioOfflineOriginalOutcome: Equatable, Sendable {
  var deleted: [PutioOfflineRemovalTarget] = []
  var failures: [PutioOfflineOriginalFailure] = []

  var failedTargets: [PutioOfflineRemovalTarget] { failures.map(\.target) }
  var retryableTargets: [PutioOfflineRemovalTarget] {
    failures.filter(\.reason.canRetry).map(\.target)
  }
}

// MARK: - Copy

/// Wording for the remove confirmation and the remote-failure report. The
/// remote action follows the Trash setting so a permanent delete never
/// claims recovery.
struct PutioOfflineRemovalCopy: Equatable {
  let trashEnabled: Bool

  func title(names: [String]) -> String {
    if names.count == 1, let name = names.first {
      return String(localized: "Remove “\(name)”?")
    }
    return String(localized: "Remove \(names.count) downloads?")
  }

  func localActionTitle(count: Int) -> String {
    count == 1 ? String(localized: "Remove download") : String(localized: "Remove downloads")
  }

  func remoteActionTitle(count: Int) -> String {
    switch (trashEnabled, count == 1) {
    case (true, true): String(localized: "Remove download and move original to Trash")
    case (true, false): String(localized: "Remove downloads and move originals to Trash")
    case (false, true): String(localized: "Remove download and delete original")
    case (false, false): String(localized: "Remove downloads and delete originals")
    }
  }

  func message(count: Int) -> String {
    let local =
      count == 1
      ? String(
        localized:
          "Removing the download frees space on this device only; the file stays on put.io.")
      : String(
        localized:
          "Removing the downloads frees space on this device only; the files stay on put.io.")
    let remote: String
    switch (trashEnabled, count == 1) {
    case (true, true):
      remote =
        String(
          localized:
            "Moving the original to Trash removes it from every device signed in to your account until you restore it."
        )
    case (true, false):
      remote =
        String(
          localized:
            "Moving the originals to Trash removes them from every device signed in to your account until you restore them."
        )
    case (false, true):
      remote =
        String(
          localized:
            "Deleting the original removes it from every device signed in to your account and cannot be undone."
        )
    case (false, false):
      remote =
        String(
          localized:
            "Deleting the originals removes them from every device signed in to your account and cannot be undone."
        )
    }
    return "\(local) \(remote)"
  }

  /// Named after what the confirmation authorized, not the setting now.
  func failureTitle(outcome: PutioOfflineOriginalOutcome) -> String {
    let single = outcome.failures.count == 1
    let modes = Set(outcome.failures.map(\.target.movesToTrash))
    switch modes {
    case [true]:
      return single
        ? String(localized: "Could not move original to Trash")
        : String(localized: "Could not move originals to Trash")
    case [false]:
      return single
        ? String(localized: "Could not delete original")
        : String(localized: "Could not delete originals")
    default:
      return single
        ? String(localized: "Could not remove original from put.io")
        : String(localized: "Could not remove originals from put.io")
    }
  }

  func failureMessage(outcome: PutioOfflineOriginalOutcome) -> String {
    let failures = outcome.failures
    let names = failures.map { "“\($0.target.name)”" }.joined(separator: ", ")
    let removed =
      failures.count == 1
      ? String(
        localized:
          "\(names) was removed from this device, but put.io did not confirm the original was removed."
      )
      : String(
        localized:
          "\(names) were removed from this device, but put.io did not confirm the originals were removed."
      )
    let drifted = failures.filter { $0.reason == .trashSettingChanged }
    let retryable = Set(failures.filter(\.reason.canRetry).map(\.reason))
    var sentences = [removed]
    if !drifted.isEmpty {
      let single = drifted.count == 1
      if drifted.count == failures.count {
        sentences.append(
          single
            ? String(
              localized:
                "The original was not sent to put.io because your Trash setting changed after you confirmed; remove it from Files if you still want to."
            )
            : String(
              localized:
                "The originals were not sent to put.io because your Trash setting changed after you confirmed; remove them from Files if you still want to."
            )
        )
      } else {
        let those = drifted.map { "“\($0.target.name)”" }.joined(separator: ", ")
        sentences.append(
          single
            ? String(
              localized:
                "\(those) was not sent to put.io because your Trash setting changed after you confirmed; remove it from Files if you still want to."
            )
            : String(
              localized:
                "\(those) were not sent to put.io because your Trash setting changed after you confirmed; remove them from Files if you still want to."
            )
        )
      }
    }
    if retryable.contains(.transient) {
      sentences.append(String(localized: "Check your connection and try again."))
    } else if retryable.contains(.settingUnconfirmed) {
      sentences.append(
        String(localized: "Your account settings could not be confirmed. Try again."))
    } else if retryable.contains(.rateLimited) {
      sentences.append(
        String(localized: "put.io is receiving too many requests. Try again shortly."))
    } else if !retryable.isEmpty {
      sentences.append(String(localized: "Something went wrong. Try again."))
    }
    return sentences.joined(separator: " ")
  }
}
