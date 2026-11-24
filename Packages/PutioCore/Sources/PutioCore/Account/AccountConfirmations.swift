import Foundation

/// The words of a confirmation: what it asks, why, and the button that agrees.
public struct PutioConfirmation: Equatable, Sendable {
  public let title: String
  public let message: String
  public let confirmTitle: String

  public init(title: String, message: String, confirmTitle: String) {
    self.title = title
    self.message = message
    self.confirmTitle = confirmTitle
  }
}

extension PutioConfirmAlert {
  public init(
    _ confirmation: PutioConfirmation, confirm: @escaping @MainActor @Sendable () -> Void
  ) {
    self.init(
      title: confirmation.title, message: confirmation.message,
      confirmTitle: confirmation.confirmTitle, confirm: confirm)
  }
}

/// Account settings that lose data or end the session ask first.
public enum PutioAccountConfirmations {
  public static var trashOff: PutioConfirmation {
    PutioConfirmation(
      title: String(localized: "Turn off trash?", bundle: .module),
      message: String(
        localized:
          "Turning off trash empties it now. Files you delete after that can’t be restored.",
        bundle: .module),
      confirmTitle: String(localized: "Turn off", bundle: .module))
  }

  public static var historyOff: PutioConfirmation {
    PutioConfirmation(
      title: String(localized: "Turn off history?", bundle: .module),
      message: String(
        localized:
          "Existing history will be cleared and new account events will no longer be saved.",
        bundle: .module),
      confirmTitle: String(localized: "Turn off", bundle: .module))
  }

  public static var resumeOff: PutioConfirmation {
    PutioConfirmation(
      title: String(localized: "Turn off resume?", bundle: .module),
      message: String(
        localized: "This erases every saved playback position on your account, on all devices.",
        bundle: .module),
      confirmTitle: String(localized: "Turn off", bundle: .module))
  }

  public static var resetFolderSorts: PutioConfirmation {
    PutioConfirmation(
      title: String(localized: "Reset all folder sorts?", bundle: .module),
      message: String(
        localized: "Every folder will use your account’s default sort.", bundle: .module),
      confirmTitle: String(localized: "Reset folder sorts", bundle: .module))
  }

  public static func signOut(device: PutioDevice) -> PutioConfirmation {
    PutioSignOutPrompt(device: device, sizeInMessage: false).confirmation
  }
}

/// Signing out keeps a phone's downloads unless the user also removes them.
/// At the largest text sizes the downloaded size moves from the button into
/// the message, so the button label stays short.
public struct PutioSignOutPrompt: Equatable, Sendable {
  public let device: PutioDevice
  public let sizeInMessage: Bool

  public init(device: PutioDevice, sizeInMessage: Bool) {
    self.device = device
    self.sizeInMessage = sizeInMessage
  }

  public var title: String {
    device == .appleTV
      ? String(localized: "Sign out?", bundle: .module)
      : String(localized: "Sign out of put.io?", bundle: .module)
  }

  public var message: String {
    switch device {
    case .iPhone:
      String(
        localized: "Downloads stay on this iPhone and come back when you sign in again.",
        bundle: .module)
    case .iPad:
      String(
        localized: "Downloads stay on this iPad and come back when you sign in again.",
        bundle: .module)
    case .appleTV:
      String(
        localized: "You’ll need a new code to sign in on this Apple TV again.", bundle: .module)
    }
  }

  public var confirmTitle: String { String(localized: "Sign out", bundle: .module) }

  public var confirmation: PutioConfirmation {
    PutioConfirmation(title: title, message: message, confirmTitle: confirmTitle)
  }

  public func message(downloadedBytes bytes: Int64, locale: Locale = .current) -> String {
    guard sizeInMessage, bytes > 0 else { return message }
    let size = PutioFileRowModel.sizeText(bytes: bytes, locale: locale)
    switch device {
    case .iPad:
      return String(
        localized:
          "Downloads use \(size) and stay on this iPad. They come back when you sign in again.",
        bundle: .module)
    case .iPhone, .appleTV:
      return String(
        localized:
          "Downloads use \(size) and stay on this iPhone. They come back when you sign in again.",
        bundle: .module)
    }
  }

  public func removeDownloadsTitle(downloadedBytes bytes: Int64, locale: Locale = .current)
    -> String
  {
    guard !sizeInMessage, bytes > 0 else {
      return String(localized: "Sign out and remove downloads", bundle: .module)
    }
    let size = PutioFileRowModel.sizeText(bytes: bytes, locale: locale)
    return String(localized: "Sign out and remove downloads (\(size))", bundle: .module)
  }
}
