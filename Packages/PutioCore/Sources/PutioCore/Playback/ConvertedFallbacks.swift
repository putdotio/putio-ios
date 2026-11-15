import Foundation

@MainActor
public final class PutioConvertedFallbacks {
  public static let limit = 200

  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, accountID: Int) {
    self.defaults = defaults
    key = Self.key(accountID: accountID)
  }

  public func contains(_ fileID: PutioFileID) -> Bool {
    stored.contains(fileID.rawValue)
  }

  public func remember(_ fileID: PutioFileID) {
    var ids = stored.filter { $0 != fileID.rawValue }
    ids.append(fileID.rawValue)
    defaults.set(Array(ids.suffix(Self.limit)), forKey: key)
  }

  public static func clear(defaults: UserDefaults = .standard, accountID: Int) {
    defaults.removeObject(forKey: key(accountID: accountID))
  }

  private var stored: [Int] {
    (defaults.array(forKey: key) as? [Int]) ?? []
  }

  private static func key(accountID: Int) -> String {
    "putio.playback.converted-fallbacks.\(accountID)"
  }
}
