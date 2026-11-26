import Foundation
import Synchronization

public enum PutioTokenStoreError: Error, Equatable {
  case keychainFailure(Int32)
}

public protocol PutioTokenStore: Sendable {
  func read() throws -> String?
  func readSignOutPending() throws -> Bool
  func write(_ token: String) throws
  func markSignOutPending() throws
  func clear() throws
}

public final class PutioInMemoryTokenStore: PutioTokenStore {
  private struct Credential {
    var token: String?
    var signOutPending = false
  }

  private let credential: Mutex<Credential>

  public init(token: String? = nil) {
    credential = Mutex(Credential(token: token))
  }

  public func read() throws -> String? {
    credential.withLock { $0.token }
  }

  public func readSignOutPending() throws -> Bool {
    credential.withLock { $0.token != nil && $0.signOutPending }
  }

  public func write(_ token: String) throws {
    credential.withLock { $0 = Credential(token: token) }
  }

  public func markSignOutPending() throws {
    credential.withLock { $0.signOutPending = $0.token != nil }
  }

  public func clear() throws {
    credential.withLock { $0 = Credential() }
  }
}
