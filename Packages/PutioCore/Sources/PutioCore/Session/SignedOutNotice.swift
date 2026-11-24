import Foundation

/// The device a sentence names, such as "this iPad".
public enum PutioDevice: Equatable, Sendable {
  case iPhone
  case iPad
  case appleTV
}

/// Why the app is signed out, as the sign-in screen explains it. A fresh or
/// user-chosen sign-out has no notice.
public struct PutioSignedOutNotice: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case sessionExpired
    case signInFailed
    case restoreFailed(PutioRestoreFailureCause)
  }

  public let kind: Kind
  public let device: PutioDevice
  public let title: String
  public let message: String

  public init?(reason: PutioSignedOutReason?, device: PutioDevice) {
    switch reason {
    case nil, .userSignedOut: return nil
    case .sessionExpired: self.init(kind: .sessionExpired, device: device)
    case .authenticationFailed: self.init(kind: .signInFailed, device: device)
    case .restoreFailed(let cause, _): self.init(kind: .restoreFailed(cause), device: device)
    }
  }

  public init(kind: Kind, device: PutioDevice) {
    self.kind = kind
    self.device = device
    switch kind {
    case .sessionExpired:
      title = String(localized: "Session expired", bundle: .module)
      message = String(localized: "Please sign in again", bundle: .module)
    case .signInFailed:
      title = String(localized: "Sign-in didn’t finish", bundle: .module)
      message = String(localized: "Nothing was saved, so you can try again.", bundle: .module)
    case .restoreFailed(.sessionCheck):
      if device == .appleTV {
        title = String(localized: "Can’t connect to put.io", bundle: .module)
        message = String(
          localized:
            "Check your internet connection. Your sign-in is saved, and the app tries again on its own.",
          bundle: .module)
      } else {
        title = String(localized: "Couldn’t check your session", bundle: .module)
        message = String(
          localized: "Your sign-in is still saved. Check your connection and try again.",
          bundle: .module)
      }
    case .restoreFailed(.secureStorage):
      title = String(localized: "Secure storage is unavailable", bundle: .module)
      message = Self.secureStorageMessage(device: device)
    }
  }

  /// The two ways out of a failed restore: retry it, or abandon the saved
  /// sign-in. Other notices have none.
  public struct RestoreActions: Equatable, Sendable {
    public let retryTitle: String
    public let discardTitle: String
  }

  public var restoreActions: RestoreActions? {
    switch kind {
    case .restoreFailed(.sessionCheck):
      RestoreActions(
        retryTitle: device == .appleTV
          ? String(localized: "Try now", bundle: .module)
          : String(localized: "Try again", bundle: .module),
        discardTitle: String(localized: "Sign in again", bundle: .module))
    case .restoreFailed(.secureStorage):
      RestoreActions(
        retryTitle: String(localized: "Try again", bundle: .module),
        discardTitle: String(localized: "Reset and sign in", bundle: .module))
    case .sessionExpired, .signInFailed: nil
    }
  }

  private static func secureStorageMessage(device: PutioDevice) -> String {
    switch device {
    case .iPhone:
      String(
        localized:
          "Your session couldn’t be read or saved safely on this iPhone. Reset clears it so you can sign in again.",
        bundle: .module)
    case .iPad:
      String(
        localized:
          "Your session couldn’t be read or saved safely on this iPad. Reset clears it so you can sign in again.",
        bundle: .module)
    case .appleTV:
      String(
        localized:
          "Your session couldn’t be read or saved safely on this Apple TV. Reset clears it so you can sign in again.",
        bundle: .module)
    }
  }
}
