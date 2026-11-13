import Foundation
import Security
import Synchronization

public enum PutioTokenStoreError: Error, Equatable {
  case keychainFailure(OSStatus)
}

public protocol PutioTokenStore: Sendable {
  func read() throws -> String?
  func readSignOutPending() throws -> Bool
  func write(_ token: String) throws
  func markSignOutPending() throws
  func clear() throws
}

// Keychain-backed token storage keyed to the app identity. The token is
// available after first unlock so a background relaunch can restore the
// session, and it never syncs off the device.
public struct PutioKeychainTokenStore: PutioTokenStore {
  private let service: String
  private let account = "putio-oauth-token"
  private static let savedMark = Data("saved".utf8)
  private static let signOutPendingMark = Data("sign-out-pending".utf8)

  public init(service: String? = nil) {
    self.service = service ?? Bundle.main.bundleIdentifier ?? "io.put.dev"
  }

  public func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
        !token.isEmpty
      else {
        return nil
      }
      return token
    case errSecItemNotFound:
      return nil
    default:
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  public func readSignOutPending() throws -> Bool {
    var query = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      let attributes = result as? [String: Any]
      return attributes?[kSecAttrGeneric as String] as? Data == Self.signOutPendingMark
    case errSecItemNotFound:
      return false
    default:
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  public func write(_ token: String) throws {
    let data = Data(token.utf8)
    var update = [String: Any]()
    update[kSecValueData as String] = data
    update[kSecAttrGeneric as String] = Self.savedMark
    // Items written before this policy keep their old class unless reapplied.
    update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw PutioTokenStoreError.keychainFailure(updateStatus)
    }

    var add = baseQuery
    add[kSecValueData as String] = data
    add[kSecAttrGeneric as String] = Self.savedMark
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw PutioTokenStoreError.keychainFailure(addStatus)
    }
  }

  public func markSignOutPending() throws {
    let update = [kSecAttrGeneric as String: Self.signOutPendingMark]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  public func clear() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
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
