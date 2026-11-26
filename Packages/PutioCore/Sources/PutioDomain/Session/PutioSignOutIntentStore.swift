import Foundation
import Synchronization

public protocol PutioSignOutIntentStore: Sendable {
  var isPending: Bool { get }
  func setPending(_ pending: Bool)
}

public final class PutioUserDefaultsSignOutIntentStore: PutioSignOutIntentStore,
  @unchecked Sendable
{
  public static let defaultKey = "putio.session.sign-out-pending"

  private let defaults: UserDefaults
  private let key: String

  public init(
    defaults: UserDefaults = .standard, key: String = PutioUserDefaultsSignOutIntentStore.defaultKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  public var isPending: Bool { defaults.bool(forKey: key) }

  public func setPending(_ pending: Bool) {
    if pending {
      defaults.set(true, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

public final class PutioInMemorySignOutIntentStore: PutioSignOutIntentStore {
  private let pending: Mutex<Bool>

  public init(pending: Bool = false) {
    self.pending = Mutex(pending)
  }

  public var isPending: Bool { pending.withLock { $0 } }

  public func setPending(_ pending: Bool) {
    self.pending.withLock { $0 = pending }
  }
}
