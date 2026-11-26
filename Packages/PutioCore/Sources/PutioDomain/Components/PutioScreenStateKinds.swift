import Foundation

public enum PutioKaomoji: String, CaseIterable, Sendable {
  case shrug = "¯\\_(ツ)_/¯"
  case knockedOut = "(×_×)"
  case uneasy = "(・_・;)"
  case nothingYet = "( ˘▽˘)っ"
  case curious = "(・ω・)"
  case emptyFolder = "[ ]"
  case nothingHere = "ᕕ( ᐛ )ᕗ"
}

public enum PutioScreenErrorKind: CaseIterable, Sendable {
  case failed
  case offline

  public var title: String {
    switch self {
    case .failed: String(localized: "Couldn’t load this", bundle: .module)
    case .offline: String(localized: "put.io is out of reach", bundle: .module)
    }
  }

  public var message: String {
    switch self {
    case .failed:
      String(localized: "Check your connection and try again.", bundle: .module)
    case .offline:
      String(
        localized: "Your connection dropped, or we did. Retrying on its own.", bundle: .module)
    }
  }
}
