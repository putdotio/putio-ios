import Foundation

/// The text of one search screen state, with its optional glyph.
public struct PutioSearchStateCopy: Equatable, Sendable {
  public let kaomoji: PutioKaomoji?
  public let title: String
  public let message: String

  init(kaomoji: PutioKaomoji? = nil, title: String, message: String) {
    self.kaomoji = kaomoji
    self.title = title
    self.message = message
  }
}

/// Search copy for each state, the same on iOS and Apple TV apart from what
/// each board draws.
public enum PutioSearchResultPresentation {
  public static var prompt: String { String(localized: "Search your files", bundle: .module) }

  public static var searching: String { String(localized: "Searching files", bundle: .module) }

  public static var start: PutioSearchStateCopy {
    #if os(tvOS)
      PutioSearchStateCopy(
        kaomoji: .curious, title: prompt,
        message: String(localized: "Type or dictate a file or folder name.", bundle: .module))
    #else
      PutioSearchStateCopy(
        title: String(localized: "Find your files", bundle: .module),
        message: String(
          localized: "Enter a name or keyword to search your put.io account.", bundle: .module))
    #endif
  }

  public static func failed(_ failure: PutioBrowserErrorPresentation) -> PutioSearchStateCopy {
    #if os(tvOS)
      if failure.isOffline {
        return PutioSearchStateCopy(
          kaomoji: .knockedOut,
          title: String(localized: "Can't connect to put.io", bundle: .module),
          message: PutioScreenErrorKind.failed.message)
      }
      return PutioSearchStateCopy(
        kaomoji: .knockedOut, title: String(localized: "Couldn’t search", bundle: .module),
        message: failure.message)
    #else
      return PutioSearchStateCopy(
        title: String(localized: "Couldn’t search", bundle: .module), message: failure.message)
    #endif
  }

  /// "No files or folders named “query”." with the shown term split out, so
  /// a screen can style it.
  @MainActor
  public static func nothingMatches(_ query: String) -> (copy: PutioSearchStateCopy, term: String) {
    let term = PutioFileSearchModel.shownTerm(query)
    #if os(tvOS)
      let kaomoji = PutioKaomoji.uneasy
    #else
      let kaomoji = PutioKaomoji.shrug
    #endif
    return (
      PutioSearchStateCopy(
        kaomoji: kaomoji, title: String(localized: "Nothing matches", bundle: .module),
        message: String(
          localized: "No files or folders named \(termMark). Try fewer words.", bundle: .module)),
      term
    )
  }

  /// Stands in for the term in `nothingMatches`' message.
  public static let termMark = "\u{FFFC}"
}

public enum PutioRecentSearchesCopy {
  public static var title: String { String(localized: "Recent searches", bundle: .module) }

  public static var clear: String { String(localized: "Clear", bundle: .module) }

  public static var remove: String {
    String(localized: "Remove from recent searches", bundle: .module)
  }

  public static func remove(_ term: String) -> String {
    String(localized: "Remove \(term) from recent searches", bundle: .module)
  }

  public static var editFailed: String {
    String(localized: "Couldn’t update recent searches", bundle: .module)
  }
}

public enum PutioHomeCopy {
  public static var continueWatching: String {
    String(localized: "Continue watching", bundle: .module)
  }

  public static var removeFromContinueWatching: String {
    String(localized: "Remove from Continue watching", bundle: .module)
  }

  public static func timeLeft(_ entry: PutioContinueWatchingEntry) -> String {
    String(localized: "\(entry.remainingClock) left", bundle: .module)
  }

  public static func resume(_ entry: PutioContinueWatchingEntry) -> String {
    String(localized: "Resume \(entry.name), \(entry.remainingSpoken) left", bundle: .module)
  }

  public static var pinned: String { String(localized: "Pinned", bundle: .module) }

  public static var nothingPinned: String {
    String(localized: "Nothing pinned yet.", bundle: .module)
  }

  public static var nothingPinnedHint: String {
    String(localized: "Pin a folder or file from its actions to keep it here.", bundle: .module)
  }

  public static func itemCount(_ count: Int) -> String {
    String(localized: "\(count) items", bundle: .module)
  }
}

public enum PutioPinnedCopy {
  public static func location(_ folder: String) -> String {
    String(localized: "in \(folder)", bundle: .module)
  }
}

extension PutioContinueWatchingModel {
  /// Wraps a playback position report so every saved position also feeds
  /// Continue watching, on any player.
  public func feeding(
    _ report: @escaping @MainActor @Sendable (PutioFileID, Int) async throws -> Void
  ) -> @MainActor @Sendable (PutioFileID, Int) async throws -> Void {
    { [weak self] fileID, seconds in
      try await report(fileID, seconds)
      self?.positionSaved(fileID: fileID, seconds: seconds)
    }
  }
}
