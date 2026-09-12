import Foundation
import PutioCore

// MARK: - Outcome

/// A download the user asked to remove, kept by name because the queue row is
/// gone by the time a remote failure is reported.
struct PutioOfflineRemovalTarget: Identifiable, Equatable, Sendable {
  let id: PutioFileID
  let name: String
}

/// Why put.io refused to take the original. A missing original is not a
/// failure: the requested end state already holds, so the queue counts it as
/// deleted. Every reason listed here is offered a retry.
struct PutioOfflineOriginalFailure: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case transient
    case rateLimited
    case unknown

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
}

// MARK: - Copy

/// Wording for the remove confirmation and the remote-failure report. The
/// local action is always the default; touching the original is worded as a
/// separate destructive choice that follows the account's Trash setting so a
/// permanent delete never claims recovery.
struct PutioOfflineRemovalCopy: Equatable {
  let trashEnabled: Bool

  func title(names: [String]) -> String {
    if names.count == 1, let name = names.first {
      return "Remove “\(name)”?"
    }
    return "Remove \(names.count) downloads?"
  }

  func localActionTitle(count: Int) -> String {
    count == 1 ? "Remove download" : "Remove downloads"
  }

  func remoteActionTitle(count: Int) -> String {
    let downloads = count == 1 ? "download" : "downloads"
    let originals = count == 1 ? "original" : "originals"
    return trashEnabled
      ? "Remove \(downloads) and move \(originals) to Trash"
      : "Remove \(downloads) and delete \(originals)"
  }

  func message(count: Int) -> String {
    let local =
      count == 1
      ? "Removing the download frees space on this device only; the file stays on put.io."
      : "Removing the downloads frees space on this device only; the files stay on put.io."
    let remote: String
    switch (trashEnabled, count == 1) {
    case (true, true):
      remote =
        "Moving the original to Trash removes it from every device signed in to your account until you restore it."
    case (true, false):
      remote =
        "Moving the originals to Trash removes them from every device signed in to your account until you restore them."
    case (false, true):
      remote =
        "Deleting the original removes it from every device signed in to your account and cannot be undone."
    case (false, false):
      remote =
        "Deleting the originals removes them from every device signed in to your account and cannot be undone."
    }
    return "\(local) \(remote)"
  }

  func failureTitle(outcome: PutioOfflineOriginalOutcome) -> String {
    let originals = outcome.failures.count == 1 ? "original" : "originals"
    return trashEnabled
      ? "Could not move \(originals) to Trash"
      : "Could not delete \(originals)"
  }

  func failureMessage(outcome: PutioOfflineOriginalOutcome) -> String {
    let failures = outcome.failures
    let names = failures.map { "“\($0.target.name)”" }.joined(separator: ", ")
    let removed =
      failures.count == 1
      ? "\(names) was removed from this device, but the original is still on put.io."
      : "\(names) were removed from this device, but the originals are still on put.io."
    let reasons = Set(failures.map(\.reason))
    let cause: String
    if reasons.contains(.transient) {
      cause = "Check your connection and try again."
    } else if reasons.contains(.rateLimited) {
      cause = "put.io is receiving too many requests. Try again shortly."
    } else {
      cause = "Something went wrong. Try again."
    }
    return "\(removed) \(cause)"
  }
}
